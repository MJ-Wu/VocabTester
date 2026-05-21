import SwiftUI

// MARK: - Data  (CET-4 四级词库，共 4414 词)

struct WordPair: Codable, Equatable {
    let chinese: String
    let english: String
}

/// Loaded from vocab.json at runtime — avoids the Swift compiler memory explosion
/// caused by a 4414-entry inline array literal.
let wordBank: [WordPair] = {
    guard let url = Bundle.main.url(forResource: "vocab", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let words = try? JSONDecoder().decode([WordPair].self, from: data) else {
        fatalError("Missing vocab.json — add it to the app target in Xcode.")
    }
    return words
}()

// MARK: - Wrong Book

struct WrongBookEntry: Codable, Equatable {
    let word: WordPair
    var correctCount: Int = 0
}

private let wrongBookKey = "CET4_wrongBook"

func loadWrongBook() -> [WrongBookEntry] {
    guard let data = UserDefaults.standard.data(forKey: wrongBookKey),
          let entries = try? JSONDecoder().decode([WrongBookEntry].self, from: data) else { return [] }
    return entries
}

func saveWrongBook(_ entries: [WrongBookEntry]) {
    if let data = try? JSONEncoder().encode(entries) {
        UserDefaults.standard.set(data, forKey: wrongBookKey)
    }
}

// MARK: - Quiz State

enum QuizPhase { case start, testing, summary }
enum AnswerState { case idle, correct, wrong }

struct QuizSession {
    var words: [WordPair]
    var index: Int = 0
    var correctCount: Int = 0
    var wrongItems: [WordPair] = []

    var current: WordPair? { index < words.count ? words[index] : nil }
    var progress: Double   { words.isEmpty ? 0 : Double(index) / Double(words.count) }
    var isFinished: Bool   { index >= words.count }
}

// MARK: - ViewModel

@MainActor
final class QuizViewModel: ObservableObject {
    @Published var phase: QuizPhase = .start
    @Published var session: QuizSession = QuizSession(words: [])
    @Published var inputText: String = ""
    @Published var answerState: AnswerState = .idle
    @Published var showAnswer: Bool = false
    @Published var selectedCount: Int = 20
    @Published var waitingForNext: Bool = false
    @Published var wrongBook: [WrongBookEntry] = loadWrongBook()
    @Published var isWrongBookMode = false

    let countOptions = [20, 50, 100, 0]
    func countLabel(_ n: Int) -> String { n == 0 ? "全部" : "\(n) 题" }

    var wrongBookCount: Int { wrongBook.count }

    func startQuiz() {
        isWrongBookMode = false
        let pool = wordBank.shuffled()
        let words = selectedCount == 0 ? pool : Array(pool.prefix(selectedCount))
        session = QuizSession(words: words)
        inputText = ""
        answerState = .idle
        showAnswer = false
        waitingForNext = false
        phase = .testing
    }

    func startWrongBookQuiz() {
        guard !wrongBook.isEmpty else { return }
        isWrongBookMode = true
        let pool = wrongBook.shuffled()
        let entries = selectedCount == 0 ? pool : Array(pool.prefix(selectedCount))
        session = QuizSession(words: entries.map(\.word))
        inputText = ""
        answerState = .idle
        showAnswer = false
        waitingForNext = false
        phase = .testing
    }

    func submitOrNext() {
        if waitingForNext { advanceToNext() }
        else              { submitAnswer()  }
    }

    private func submitAnswer() {
        guard let current = session.current,
              !inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let user    = inputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let correct = current.english.lowercased()

        if user == correct {
            session.correctCount += 1
            answerState = .correct
            showAnswer  = false
            waitingForNext = true

            if isWrongBookMode {
                markWrongBookCorrect(current)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.advanceToNext()
            }
        } else {
            session.wrongItems.append(current)
            answerState = .wrong
            showAnswer  = true
            waitingForNext = true

            if isWrongBookMode {
                resetWrongBookCorrect(current)
            } else {
                addToWrongBook(current)
            }
        }
    }

    private func addToWrongBook(_ word: WordPair) {
        guard !wrongBook.contains(where: { $0.word.english == word.english }) else { return }
        wrongBook.append(WrongBookEntry(word: word, correctCount: 0))
        saveWrongBook(wrongBook)
    }

    private func markWrongBookCorrect(_ word: WordPair) {
        guard let idx = wrongBook.firstIndex(where: { $0.word.english == word.english }) else { return }
        wrongBook[idx].correctCount += 1
        if wrongBook[idx].correctCount >= 2 {
            wrongBook.remove(at: idx)
        }
        saveWrongBook(wrongBook)
    }

    private func resetWrongBookCorrect(_ word: WordPair) {
        guard let idx = wrongBook.firstIndex(where: { $0.word.english == word.english }) else { return }
        wrongBook[idx].correctCount = 0
        saveWrongBook(wrongBook)
    }

    private func advanceToNext() {
        guard waitingForNext else { return }
        session.index += 1
        inputText = ""
        answerState = .idle
        showAnswer = false
        waitingForNext = false
        if session.isFinished { phase = .summary }
    }

    var scorePercent: Int {
        let total = session.correctCount + session.wrongItems.count
        guard total > 0 else { return 0 }
        return Int(Double(session.correctCount) / Double(total) * 100)
    }
}

// MARK: - App Entry

@main
struct VocabTesterApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.titleBar)
            .windowResizability(.contentMinSize)
            .defaultSize(width: 640, height: 560)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var vm = QuizViewModel()
    var body: some View {
        Group {
            switch vm.phase {
            case .start:   StartView(vm: vm)
            case .testing: TestingView(vm: vm)
            case .summary: SummaryView(vm: vm)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .animation(.easeInOut(duration: 0.22), value: vm.phase)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Start View

struct StartView: View {
    @ObservedObject var vm: QuizViewModel

    var body: some View {
        VStack(spacing: 36) {
            Spacer()

            VStack(spacing: 10) {
                Text("CET-4 单词测试")
                    .font(.system(size: 34, weight: .light, design: .serif))
                Text("大学英语四级词库 · 共 4414 词")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("看中文释义，填写对应的英文单词")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 12) {
                Label("题目数量", systemImage: "list.number")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    ForEach(vm.countOptions, id: \.self) { n in
                        Button(vm.countLabel(n)) { vm.selectedCount = n }
                            .buttonStyle(SegmentButtonStyle(isSelected: vm.selectedCount == n))
                    }
                }
            }

            VStack(spacing: 10) {
                Button("开始测试") { vm.startQuiz() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])

                Button("错题测试 · \(vm.wrongBookCount) 词") { vm.startWrongBookQuiz() }
                    .buttonStyle(OutlineButtonStyle())
                    .opacity(vm.wrongBook.isEmpty ? 0.35 : 1)
                    .disabled(vm.wrongBook.isEmpty)
            }

            Spacer()
        }
        .padding(52)
    }
}

// MARK: - Testing View

struct TestingView: View {
    @ObservedObject var vm: QuizViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {

            HStack {
                Button { vm.phase = .start } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Text(vm.isWrongBookMode ? "错题模式" : "CET-4")
                    .font(.system(size: 13, weight: .light, design: .serif))
                    .foregroundStyle(vm.isWrongBookMode ? Color.orange : Color.secondary)
                Spacer()
                HStack(spacing: 14) {
                    StatPill(label: "正确", count: vm.session.correctCount, color: .green)
                    StatPill(label: "错误", count: vm.session.wrongItems.count, color: .orange)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 16)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.10))
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: geo.size.width * vm.session.progress)
                        .animation(.easeInOut(duration: 0.35), value: vm.session.progress)
                }
            }
            .frame(height: 2)

            Spacer()

            VStack(spacing: 10) {
                Text("中文释义")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)

                if let cur = vm.session.current {
                    let (badge, mainText) = splitBadge(cur.chinese)
                    HStack(alignment: .center, spacing: 8) {
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(.secondary)
                        Text(mainText)
                            .font(.system(size: 36, weight: .medium, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id(vm.session.index)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .animation(.easeOut(duration: 0.18), value: vm.session.index)
                }

                Text("第 \(vm.session.index + 1) 题 · 共 \(vm.session.words.count) 题")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            Spacer()

            VStack(spacing: 14) {
                TextField("输入英文单词…", text: $vm.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, design: .serif))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(inputBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(inputBorder, lineWidth: 1.5)
                            )
                    )
                    .frame(maxWidth: 360)
                    .focused($focused)
                    .onSubmit { vm.submitOrNext() }
                    .onChange(of: vm.session.index) { focused = true }
                    .autocorrectionDisabled(true)

                ZStack {
                    if vm.answerState == .correct {
                        FeedbackBadge(text: "✓ 正确", correct: true)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else if vm.answerState == .wrong {
                        VStack(spacing: 4) {
                            FeedbackBadge(text: "✗ 错误", correct: false)
                            if vm.showAnswer, let cur = vm.session.current {
                                Text("正确答案：\(cur.english)")
                                    .font(.system(size: 16, design: .serif))
                                    .italic()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .frame(height: 52)
                .animation(.easeOut(duration: 0.18), value: vm.answerState)
            }

            Spacer()

            HStack(spacing: 4) {
                Text("按").foregroundStyle(.tertiary)
                KeyBadge("↩")
                Text(vm.waitingForNext && vm.answerState == .wrong
                     ? "继续下一题" : "提交答案")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.bottom, 22)
        }
        .onAppear { focused = true }
    }

    func splitBadge(_ s: String) -> (String, String) {
        if let r1 = s.range(of: "【"), let r2 = s.range(of: "】") {
            let badge = String(s[s.index(after: r1.lowerBound)..<r2.lowerBound])
            let rest  = String(s[s.index(after: r2.lowerBound)...])
            return (badge, rest)
        }
        return ("", s)
    }

    var inputBg: Color {
        switch vm.answerState {
        case .idle:    return Color(NSColor.controlBackgroundColor)
        case .correct: return Color.green.opacity(0.07)
        case .wrong:   return Color.orange.opacity(0.07)
        }
    }
    var inputBorder: Color {
        switch vm.answerState {
        case .idle:    return Color.secondary.opacity(0.22)
        case .correct: return Color.green.opacity(0.55)
        case .wrong:   return Color.orange.opacity(0.55)
        }
    }
}

// MARK: - Summary View

struct SummaryView: View {
    @ObservedObject var vm: QuizViewModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Text(vm.isWrongBookMode ? "错题测试完成" : "测试完成")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(.tertiary)
                Text("\(vm.scorePercent)%")
                    .font(.system(size: 68, weight: .light, design: .serif))
                Text("答对 \(vm.session.correctCount) / 共 \(vm.session.correctCount + vm.session.wrongItems.count) 题")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                if vm.isWrongBookMode {
                    Text("错题库剩余 \(vm.wrongBookCount) 词")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }
            }

            if vm.session.wrongItems.isEmpty {
                Text(vm.isWrongBookMode && vm.wrongBookCount == 0
                     ? "🎉 错题库已清空！" : "🎉 全部答对！")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    Text("错误单词回顾")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(vm.session.wrongItems.enumerated()), id: \.offset) { i, item in
                                HStack {
                                    Text(item.chinese)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(item.english)
                                        .font(.system(size: 15, design: .serif))
                                        .italic()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(i % 2 == 0
                                    ? Color.clear
                                    : Color.secondary.opacity(0.04))
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 0.5))
                }
                .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button("再来一次") { vm.startQuiz() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [])
                Button("重新设置") { vm.phase = .start }
                    .buttonStyle(OutlineButtonStyle())
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }
}

// MARK: - Reusable components

struct StatPill: View {
    let label: String; let count: Int; let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.7)).frame(width: 7, height: 7)
            Text("\(count) \(label)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct FeedbackBadge: View {
    let text: String; let correct: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Capsule().fill(correct
                ? Color.green.opacity(0.12)
                : Color.orange.opacity(0.12)))
            .foregroundStyle(correct ? Color.green : Color.orange)
    }
}

struct KeyBadge: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15))
            .padding(.horizontal, 34).padding(.vertical, 11)
            .background(Color.primary)
            .foregroundColor(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .padding(.horizontal, 24).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(configuration.isPressed
                    ? Color.secondary.opacity(0.08) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)))
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SegmentButtonStyle: ButtonStyle {
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(isSelected
                ? Color.primary
                : Color.secondary.opacity(0.10)))
            .foregroundColor(isSelected
                ? Color(NSColor.windowBackgroundColor) : .primary)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
