import SwiftUI
import WebKit

// MARK: - Global Background Host Component

@MainActor
struct SAWTeamBackgroundHosts: View {
    @ObservedObject var workspace: SAWWorkspace
    let plannerHostMounted: Bool

    init(workspace: SAWWorkspace, plannerHostMounted: Bool) {
        self.workspace = workspace
        self.plannerHostMounted = plannerHostMounted
    }

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(Array(workspace.sessions.values), id: \.projectID) { session in
                    SAWSingleSessionHostView(
                        session: session,
                        selectedProjectID: workspace.selectedProjectID,
                        plannerHostMounted: plannerHostMounted
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Per-Session Host Container

@MainActor
private struct SAWSingleSessionHostView: View {
    @ObservedObject var session: SAWProjectSession
    let selectedProjectID: UUID?
    let plannerHostMounted: Bool

    var body: some View {
        Group {
            // 1. Session Coordinator Host
            SAWCoordinatorHostView(
                session: session,
                transport: session.transport,
                selectedProjectID: selectedProjectID,
                plannerHostMounted: plannerHostMounted
            )

            // 2. Session Worker AI Hosts (only if runtime exists; no instantiation)
            if let runtime = session.existingTeamRuntime {
                SAWWorkerRuntimeHostView(
                    runtime: runtime
                )
            }

            // 3. Business Tabs Hosts
            ForEach(session.tabs, id: \.tabID) { tab in
                SAWBusinessTabHostView(
                    session: session,
                    tab: tab,
                    selectedProjectID: selectedProjectID,
                    plannerHostMounted: plannerHostMounted
                )
            }
        }
    }
}

// MARK: - Coordinator Host View

@MainActor
private struct SAWCoordinatorHostView: View {
    @ObservedObject var session: SAWProjectSession
    @ObservedObject var transport: WebPageAgentTransport
    let selectedProjectID: UUID?
    let plannerHostMounted: Bool

    private var isForeground: Bool {
        plannerHostMounted &&
        selectedProjectID == session.projectID &&
        (session.showingPlannerSurface || session.needsPlannerLogin)
    }

    var body: some View {
        if !isForeground, let webView = transport.plannerWebView {
            LoginWebViewRepresentable(webView: webView, nativeInputAllowed: { false })
                .frame(width: 420, height: 500)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Worker AI Runtime Host View

@MainActor
private struct SAWWorkerRuntimeHostView: View {
    @ObservedObject var runtime: SAWTeamRuntime

    var body: some View {
        ForEach(runtime.hostedAISurfaces) { surface in
            if surface.id != runtime.activeLoginWorkerID {
                LoginWebViewRepresentable(webView: surface.webView, nativeInputAllowed: { false })
                    .frame(width: 420, height: 500)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Business Tab Host View

@MainActor
private struct SAWBusinessTabHostView: View {
    @ObservedObject var session: SAWProjectSession
    @ObservedObject var tab: LoginBrowserModel
    let selectedProjectID: UUID?
    let plannerHostMounted: Bool

    private var isForeground: Bool {
        plannerHostMounted &&
        selectedProjectID == session.projectID &&
        tab.tabID == session.selectedTabID
    }

    var body: some View {
        if !isForeground, let webView = tab.webView {
            LoginWebViewRepresentable(webView: webView, nativeInputAllowed: { false })
                .frame(width: 1280, height: 800)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
