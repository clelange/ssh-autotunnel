import AppKit

@MainActor
enum AboutPanelPresenter {
    private static let repositoryURL = URL(string: "https://github.com/clelange/ssh-autotunnel")!

    static func show() {
        AppActivation.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: repositoryCredits
        ])
    }

    private static var repositoryCredits: NSAttributedString {
        let repositoryLabel = "clelange/ssh-autotunnel"
        let credits = NSMutableAttributedString(string: "GitHub: \(repositoryLabel)")
        let linkRange = (credits.string as NSString).range(of: repositoryLabel)
        credits.addAttribute(.link, value: repositoryURL, range: linkRange)
        return credits
    }
}
