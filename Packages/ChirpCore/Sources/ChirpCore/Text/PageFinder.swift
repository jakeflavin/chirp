import Foundation

/// One element of another app's window, as the screen reader interface gives it: what it is, and what is inside it.
public protocol ScreenNode {
    var role: String { get }
    var children: [Self] { get }
}

/// Finds the page in a window: the web content an article, a message or a document is shown in.
///
/// The search used to walk the window from its first element and give up after 1,500. In Apple Mail the
/// message list comes first and holds thousands, so the message beside it was never reached, and the
/// list itself (every sender, subject and preview in the mailbox) was summarized in its place
/// (201,041 characters where the open message had 3,207).
public enum PageFinder {
    /// Lists and tables with more rows than this are not looked into: a page is not inside one of a
    /// mailbox's or a folder's hundreds of rows.
    public static let longList = 40
    public static let listRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser", "AXGrid"]
    /// Controls, which never hold a page.
    static let controlRoles: Set<String> = ["AXButton", "AXMenuBar", "AXMenu", "AXToolbar", "AXTextField", "AXPopUpButton", "AXScrollBar", "AXStaticText", "AXImage"]

    /// What a search found, and how far it had to look.
    public struct Found<Node> {
        public var pages: [Node]
        public var visited: Int
        /// Long lists that were passed over.
        public var skippedLists: Int
    }

    /// The web areas under `root`, in the order they are shown. With `all` false the search ends at the first.
    public static func pages<Node: ScreenNode>(under root: Node, all: Bool, limit: Int = 1500, depth: Int = 20) -> Found<Node> {
        var found = Found<Node>(pages: [], visited: 0, skippedLists: 0)
        func look(_ node: Node, _ level: Int) {
            guard found.visited < limit, level < depth, all || found.pages.isEmpty else { return }
            found.visited += 1
            let role = node.role
            if role == "AXWebArea" {
                found.pages.append(node)
                return
            }
            if controlRoles.contains(role) { return }
            let inside = node.children
            if listRoles.contains(role), inside.count > longList {
                found.skippedLists += 1
                return
            }
            for child in inside { look(child, level + 1) }
        }
        look(root, 0)
        return found
    }
}
