//
//  ContentView.swift
//  MBox Explorer
//
//  Main application view with sidebar, list, and preview
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MboxViewModel()
    @StateObject private var alertManager = AlertManager()
    @ObservedObject private var themeManager = ThemeManager.shared
    @EnvironmentObject var recentFilesViewModel: RecentFilesViewModel
    @State private var selectedView: SidebarItem = .allEmails
    @State private var showingFilePicker = false
    @State private var showingExportPicker = false
    @State private var showingQuickOpen = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        ZStack {
            // Theme-driven base. Replaces the fixed cyan/purple/pink animated
            // GlassmorphicBackground (which ignored the selected theme) so the
            // chosen theme — including true-black AMOLED — actually shows.
            themeManager.backgroundColor(for: themeManager.currentTheme)
                .ignoresSafeArea()

            mainView
                .modifier(SheetsModifier(viewModel: viewModel, alertManager: alertManager, showingExportPicker: $showingExportPicker))
                .modifier(NotificationsModifier(viewModel: viewModel, columnVisibility: $columnVisibility, showingFilePicker: $showingFilePicker, showingQuickOpen: $showingQuickOpen, copyActions: CopyActions(copyEmail: copyEmailAddress, copySubject: copySubject, copyMessageId: copyMessageId), loadFile: loadMboxFile))
                .overlay {
                    if showingQuickOpen {
                        ZStack {
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    showingQuickOpen = false
                                }

                            QuickOpenView(isPresented: $showingQuickOpen) { url in
                                loadMboxFile(url)
                            }
                        }
                    }
                }
                .onAppear {
                    viewModel.alertManager = alertManager
                    // Re-apply once the window exists so window-chrome theming
                    // takes effect on first launch (init runs before any window).
                    themeManager.applyTheme()
                }
                .fileDropTarget { url in
                    loadMboxFile(url)
                }
        }
        // Drive the whole app's accent/selection highlight from the theme, so
        // picking a theme (Nord, Solarized, Custom…) actually recolors controls
        // and selection — not just the settings preview swatch.
        .tint(themeManager.accentColor(for: themeManager.currentTheme))
    }

    private var mainView: some View {
        Group {
            if viewModel.layoutMode == .threeColumn {
                ThreeColumnLayoutView(
                    viewModel: viewModel,
                    selectedView: $selectedView,
                    showingFilePicker: $showingFilePicker,
                    columnVisibility: $columnVisibility
                )
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(
                        viewModel: viewModel,
                        selectedView: $selectedView,
                        showingFilePicker: $showingFilePicker
                    )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
                } content: {
                    if selectedView == .ask {
                        AskView(viewModel: viewModel)
                            .navigationSplitViewColumnWidth(min: 600, ideal: 900, max: 1400)
                    } else if selectedView == .explore {
                        ExploreView(viewModel: viewModel)
                            .navigationSplitViewColumnWidth(min: 600, ideal: 900, max: 1400)
                    } else if selectedView == .network {
                        NetworkVisualizationView(emails: viewModel.emails)
                            .navigationSplitViewColumnWidth(min: 600, ideal: 900, max: 1400)
                    } else if selectedView == .attachments {
                        AttachmentsView(viewModel: viewModel)
                            .navigationSplitViewColumnWidth(min: 300, ideal: 600, max: 900)
                    } else if selectedView == .analytics {
                        AnalyticsView(viewModel: viewModel)
                            .navigationSplitViewColumnWidth(min: 300, ideal: 800, max: 1200)
                    } else if selectedView == .operations {
                        MboxOperationsView(viewModel: viewModel)
                            .navigationSplitViewColumnWidth(min: 300, ideal: 700, max: 1000)
                    } else {
                        EmailListView(
                            viewModel: viewModel,
                            selectedView: selectedView
                        )
                        .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
                    }
                } detail: {
                    if selectedView == .ask || selectedView == .explore || selectedView == .network || selectedView == .attachments || selectedView == .analytics || selectedView == .operations {
                        // No detail view for these views
                        let title = selectedView == .attachments ? "Select an attachment" :
                                    selectedView == .analytics ? "Analytics Dashboard" : "MBOX Operations"
                        let icon = selectedView == .attachments ? "paperclip" :
                                   selectedView == .analytics ? "chart.bar.xaxis" : "scissors"
                        let desc = selectedView == .attachments ? "Click on an attachment row to view details" :
                                   selectedView == .analytics ? "View comprehensive email statistics and insights" :
                                   "Merge multiple files or split large archives"

                        ContentUnavailableView(title, systemImage: icon, description: Text(desc))
                    } else {
                        EmailDetailView(viewModel: viewModel)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .onChange(of: showingExportPicker) { oldValue, newValue in
            if newValue {
                showExportDirectoryPicker()
            }
        }
        .toolbar {
            ToolbarCommands(viewModel: viewModel, showingFilePicker: $showingFilePicker)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            loadMboxFile(url)
        case .failure(let error):
            alertManager.showError("File Selection Error",
                                   message: "Could not open the selected file",
                                   details: error.localizedDescription)
        }
    }

    private func loadMboxFile(_ url: URL) {
        Task {
            await viewModel.loadMboxFile(url: url)
            // Add to recent files after successful load
            recentFilesViewModel.addRecent(url)
        }
    }

    private func showExportDirectoryPicker() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Ancient History Export"
        panel.message = "Choose export directory"
        panel.canCreateDirectories = true

        panel.begin { response in
            showingExportPicker = false
            if response == .OK, let url = panel.url {
                Task {
                    await viewModel.exportAll(to: url)
                }
            }
        }
    }

    private func copyEmailAddress() {
        guard let email = viewModel.selectedEmail else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email.from, forType: .string)
    }

    private func copySubject() {
        guard let email = viewModel.selectedEmail else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email.subject, forType: .string)
    }

    private func copyMessageId() {
        guard let email = viewModel.selectedEmail,
              let messageId = email.messageId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(messageId, forType: .string)
    }
}

enum SidebarItem: String, CaseIterable {
    case allEmails = "All Emails"
    case ask = "Ask AI"
    case explore = "Explore"
    case network = "Network"
    case attachments = "Attachments"
    case analytics = "Analytics"
    case operations = "Merge/Split"
    case threads = "Threads"
    case senders = "By Sender"
    case dates = "By Date"
}

// MARK: - View Modifiers

struct CopyActions {
    let copyEmail: () -> Void
    let copySubject: () -> Void
    let copyMessageId: () -> Void
}

struct SheetsModifier: ViewModifier {
    @ObservedObject var viewModel: MboxViewModel
    @ObservedObject var alertManager: AlertManager
    @Binding var showingExportPicker: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showingExportOptions) {
                ExportOptionsView(viewModel: viewModel, showingExportPicker: $showingExportPicker)
            }
            .sheet(isPresented: $viewModel.showingProgressSheet) {
                ProgressSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showingExportProgress) {
                ExportProgressSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showingSmartFilters) {
                SmartFiltersView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showingEmailComparison) {
                if let email1 = viewModel.selectedEmail,
                   let email2 = viewModel.comparisonEmail {
                    EmailComparisonView(email1: email1, email2: email2, isPresented: $viewModel.showingEmailComparison)
                }
            }
            .sheet(isPresented: $viewModel.showingRegexSearch) {
                RegexSearchView(viewModel: viewModel, isPresented: $viewModel.showingRegexSearch)
            }
            .sheet(isPresented: $viewModel.showingRedactionTool) {
                RedactionToolView(viewModel: viewModel, isPresented: $viewModel.showingRedactionTool)
            }
            .sheet(isPresented: $viewModel.showingThemeSettings) {
                ThemeSettingsView(isPresented: $viewModel.showingThemeSettings)
            }
            .sheet(isPresented: $viewModel.showingAbout) {
                AboutView(isPresented: $viewModel.showingAbout)
            }
            // Note: Add DuplicatesView.swift to Xcode project to enable this feature
            // .sheet(isPresented: $viewModel.showingDuplicates) {
            //     DuplicatesView(viewModel: viewModel)
            // }
            .alert(alertManager.alertTitle, isPresented: $alertManager.showingAlert) {
                Button("OK", role: .cancel) { }
                if !alertManager.detailsText.isEmpty {
                    Button("Show Details") {
                        alertManager.showDetails = true
                    }
                }
            } message: {
                Text(alertManager.alertMessage)
            }
            .sheet(isPresented: $alertManager.showDetails) {
                ErrorDetailsView(details: alertManager.detailsText)
            }
    }
}

struct NotificationsModifier: ViewModifier {
    @ObservedObject var viewModel: MboxViewModel
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showingFilePicker: Bool
    @Binding var showingQuickOpen: Bool
    let copyActions: CopyActions
    let loadFile: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(FileNotifications(showingFilePicker: $showingFilePicker, showingQuickOpen: $showingQuickOpen, loadFile: loadFile))
            .modifier(ViewNotifications(viewModel: viewModel, columnVisibility: $columnVisibility))
            .modifier(ActionNotifications(viewModel: viewModel, copyActions: copyActions))
    }
}

// Split notifications into smaller groups to avoid type-checking timeout
private struct FileNotifications: ViewModifier {
    @Binding var showingFilePicker: Bool
    @Binding var showingQuickOpen: Bool
    let loadFile: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openMboxFile)) { _ in
                showingFilePicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickOpen)) { _ in
                showingQuickOpen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openRecentFile)) { notification in
                if let url = notification.object as? URL {
                    loadFile(url)
                }
            }
    }
}

private struct ViewNotifications: ViewModifier {
    @ObservedObject var viewModel: MboxViewModel
    @Binding var columnVisibility: NavigationSplitViewVisibility

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .exportAll)) { _ in
                viewModel.showingExportOptions = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showExportSettings)) { _ in
                viewModel.showingExportOptions = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                columnVisibility = columnVisibility == .all ? .detailOnly : .all
            }
            .onReceive(NotificationCenter.default.publisher(for: .showRegexSearch)) { _ in
                viewModel.showingRegexSearch = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showRedactionTool)) { _ in
                viewModel.showingRedactionTool = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showThemeSettings)) { _ in
                viewModel.showingThemeSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in
                viewModel.showingAbout = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAISettings)) { _ in
                openAISettingsWindow()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleLayoutMode)) { _ in
                viewModel.layoutMode = viewModel.layoutMode == .standard ? .threeColumn : .standard
                WindowStateManager.shared.saveLayoutMode(viewModel.layoutMode)
            }
    }

    private func openAISettingsWindow() {
        let settingsView = AISettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.title = "Ollama AI Settings"

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Ollama AI Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 700))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ActionNotifications: ViewModifier {
    @ObservedObject var viewModel: MboxViewModel
    let copyActions: CopyActions

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .navigateNext)) { _ in
                viewModel.selectNextEmail()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigatePrevious)) { _ in
                viewModel.selectPreviousEmail()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearFilters)) { _ in
                viewModel.clearAllFilters()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyEmailAddress)) { _ in
                copyActions.copyEmail()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copySubject)) { _ in
                copyActions.copySubject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyMessageId)) { _ in
                copyActions.copyMessageId()
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteEmail)) { _ in
                viewModel.deleteSelectedEmail()
            }
    }
}

// MARK: - About / Acknowledgements

/// About panel that also satisfies the MIT attribution requirement for binary
/// distribution: the original copyright + permission notice must travel with
/// every copy of the software, including the shipped app. The license text is
/// embedded (not read from a bundled file) so it can never be missing at runtime.
struct AboutView: View {
    @Binding var isPresented: Bool

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    private let upstreamURL = "https://github.com/kochj23/MBox-Explorer"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("About Ancient History").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ancient History").font(.title2.bold())
                        Text("Version \(appVersion)")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Credits").font(.subheadline.bold())
                        Text("A fork of **MBox Explorer** by Jordan Koch, used under the MIT License.")
                        Link(upstreamURL, destination: URL(string: upstreamURL)!)
                            .font(.callout)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("License").font(.subheadline.bold())
                        Text(Self.licenseText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    /// MIT License — keep in sync with the repository LICENSE file. Must include
    /// the original copyright notice and the permission notice verbatim.
    static let licenseText = """
    MIT License

    Copyright (c) 2025 Jordan Koch (MBox Explorer, the original work)
    Copyright (c) 2026 Ancient History contributors (modifications)

    Ancient History is a fork of MBox Explorer
    (https://github.com/kochj23/MBox-Explorer), used and redistributed under the
    terms of the MIT License below.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}

// MARK: - Preview
#Preview {
    ContentView()
}
