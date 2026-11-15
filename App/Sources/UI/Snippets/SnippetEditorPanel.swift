import SwiftUI
import AppKit
import AppCore
import CoreModels

/// The right-hand snippet editor, styled like Host Details. Each edit saves at once through
/// `SnippetsViewModel.update` (idempotent). Create one panel per snippet (`.id(snippetID)`): the
/// fields are loaded once, on appear, so typing never fights a re-render.
struct SnippetEditorPanel: View {
    let model: SnippetsViewModel
    let snippet: Snippet
    let onClose: () -> Void
    let onRun: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    /// "New package…" in the picker: ask for a name, then move this snippet there.
    let onNewPackage: () -> Void

    @State private var name = ""
    @State private var script = ""
    @State private var didLoad = false

    /// The package picker's choices.
    private enum PackageChoice: Hashable {
        case noPackage
        case package(String)
        case new
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DetailsCard {
                        FieldColumn(title: "Name") {
                            TextField("Name", text: $name, prompt: Text("Name shown on the card"))
                                .textFieldStyle(.roundedBorder)
                        }
                        FieldColumn(title: "Package") {
                            packagePicker
                        }
                    }
                    DetailsCard {
                        FieldColumn(title: "Script") {
                            scriptEditor
                        }
                        Text("Use {{name}} to ask for a value when running")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !placeholderNames.isEmpty {
                            Text("Asks for: \(placeholderNames.joined(separator: ", "))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Button(action: onDuplicate) {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Make a copy of this snippet")
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Remove this snippet")
                    }
                    .controlSize(.large)
                }
                .padding(16)
            }
            runButton
                .padding(16)
        }
        .frame(width: Theme.detailsPanelWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarBackground)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            name = snippet.name
            script = snippet.script
        }
        .onChange(of: name) { _, newValue in
            guard didLoad else { return }
            model.update(snippet.id, name: newValue, script: nil, package: nil)
        }
        .onChange(of: script) { _, newValue in
            guard didLoad else { return }
            model.update(snippet.id, name: nil, script: newValue, package: nil)
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Text("Snippet")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Menu {
                Button("Duplicate", action: onDuplicate)
                Button("Delete snippet", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")

            Button {
                onClose()
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var runButton: some View {
        Button {
            onRun()
        } label: {
            Text("Run on hosts\u{2026}")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open a session to each chosen host and run this snippet there")
    }

    // MARK: Fields

    private var scriptEditor: some View {
        ScriptTextEditor(text: $script)
            .frame(minHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            }
    }

    private var packagePicker: some View {
        Picker("Package", selection: packageSelection) {
            Text("None").tag(PackageChoice.noPackage)
            if !packageOptions.isEmpty {
                Divider()
                ForEach(packageOptions, id: \.self) { package in
                    Text(package).tag(PackageChoice.package(package))
                }
            }
            Divider()
            Text("New package\u{2026}").tag(PackageChoice.new)
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every package, plus this snippet's own (in case it was just renamed elsewhere).
    private var packageOptions: [String] {
        var options = model.packages
        if let current = snippet.package, !options.contains(current) {
            options.append(current)
            options.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return options
    }

    /// Reads the saved package; choosing one saves at once; "New package…" asks for a name instead.
    private var packageSelection: Binding<PackageChoice> {
        Binding(
            get: { snippet.package.map(PackageChoice.package) ?? .noPackage },
            set: { choice in
                switch choice {
                case .noPackage:
                    model.update(snippet.id, name: nil, script: nil, package: .some(nil))
                case .package(let package):
                    model.update(snippet.id, name: nil, script: nil, package: .some(package))
                case .new:
                    onNewPackage()
                }
            }
        )
    }

    /// The distinct placeholder names in the script as typed.
    private var placeholderNames: [String] {
        SnippetTemplate(script).placeholders.map(\.name)
    }
}

/// A multi-line monospaced script editor. SwiftUI's `TextEditor` follows the system's smart quotes,
/// dashes and text replacements, which would turn straight quotes into curly ones and break shell
/// commands; this `NSTextView` has every substitution off.
private struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.inlinePredictionType = .no // Tab must insert a tab, not accept a suggestion
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
