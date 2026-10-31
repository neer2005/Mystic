import SwiftUI
import AppKit

/// What VoiceOver reads for a card, and the actions it offers besides selecting it.
struct GameCardDescription {
    var label: String
    var value: String
    var actions: [(name: String,perform: () -> Void)]=[]
}

/// The keyboard model shared by Home and the host library: arrow keys move the
/// selection, the selection scrolls into view, and Return or a double-click opens it.
/// Like Finder, the selection is drawn in the accent colour only while the grid has focus.
struct GameGrid<Item: Identifiable,Card: View,Menu: View,Footer: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selection: Item.ID?
    var minimumWidth: CGFloat=140
    let label: String
    /// Return and double-click; nil when the selected item cannot be opened.
    let open: (Item) -> Void
    let describe: (Item) -> GameCardDescription
    @ViewBuilder let card: (Item) -> Card
    /// The context menu, applied to the whole cell above the click target.
    @ViewBuilder let menu: (Item) -> Menu
    @ViewBuilder var footer: () -> Footer
    @State private var focused=false
    @State private var keys=GridKeys()
    @State private var width: CGFloat=400
    private let spacing: CGFloat=16
    private var columns: Int { GridNavigation.columns(width:width,minimum:minimumWidth,spacing:spacing) }
    private var selectedItem: Item? { items.first { $0.id == selection } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:minimumWidth),spacing:spacing)],spacing:20) {
                        ForEach(items) { item in cell(item) }
                    }
                    .accessibilityElement(children:.contain)
                    .accessibilityLabel(label)
                    footer()
                }.padding(spacing)
            }
            .onGeometryChange(for:CGFloat.self) { $0.size.width-spacing*2 } action: { width=$0 }
            // Keys go through an AppKit responder: SwiftUI focus could not move into the grid
            // from the sidebar list, so arrow keys stopped working after choosing a host.
            .background {
                GridKeyCatcher(keys:keys) { move in
                    let ids=items.map(\.id)
                    guard let next=GridNavigation.target(ids:ids,from:selection,move:move,columns:columns) else { return }
                    selection=next
                    withAnimation(.default) { proxy.scrollTo(next) }
                } open: {
                    if let item=selectedItem { open(item) }
                } focusChanged: { gained in
                    focused=gained
                    if gained,selection == nil { selection=items.first?.id }
                }
            }
        }
    }
    /// The card is the accessibility element, with the actions VoiceOver was checked with.
    /// An invisible plain Button over it takes clicks and gives the grid keyboard focus.
    private func cell(_ item: Item) -> some View {
        let selected=selection == item.id,description=describe(item)
        let select={ selection=item.id;keys.focus() }
        return card(item)
            .padding(8)
            .background(selected ? highlight.opacity(0.14) : Color.clear,in:RoundedRectangle(cornerRadius:10))
            .overlay { RoundedRectangle(cornerRadius:10).strokeBorder(selected ? highlight : Color.clear,lineWidth:2) }
            .overlay {
                Button(action:select) { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count:2).onEnded { select();open(item) })
            }
            .contextMenu { menu(item) }
            .id(item.id)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(description.label)
            .accessibilityValue(description.value)
            .accessibilityAddTraits(selected ? [.isButton,.isSelected] : .isButton)
            .accessibilityAction(.default,select)
            .accessibilityActions {
                ForEach(description.actions.indices,id:\.self) { index in
                    Button(description.actions[index].name,action:description.actions[index].perform)
                }
            }
    }
    private var highlight: Color { focused ? .accentColor : .secondary }
}

extension GameGrid where Footer == EmptyView {
    init(items: [Item],selection: Binding<Item.ID?>,minimumWidth: CGFloat=140,label: String,
         open: @escaping (Item) -> Void,describe: @escaping (Item) -> GameCardDescription,
         @ViewBuilder card: @escaping (Item) -> Card,@ViewBuilder menu: @escaping (Item) -> Menu) {
        self.init(items:items,selection:selection,minimumWidth:minimumWidth,label:label,open:open,describe:describe,card:card,menu:menu,footer:{ EmptyView() })
    }
}

/// Grid arithmetic, separate from the view so it can be tested.
enum GridNavigation {
    enum Move { case left,right,up,down }
    static func columns(width: CGFloat,minimum: CGFloat,spacing: CGFloat) -> Int {
        max(1,Int((width+spacing)/(minimum+spacing)))
    }
    /// The item a move selects; with nothing selected, any move selects the first item.
    static func target<ID: Equatable>(ids: [ID],from current: ID?,move: Move,columns: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current,let index=ids.firstIndex(of:current) else { return ids.first }
        let delta: Int
        switch move {
        case .left: delta = -1
        case .right: delta = 1
        case .up: delta = -max(1,columns)
        case .down: delta = max(1,columns)
        }
        let next=index+delta
        // Up from the first row and down from the last stay put rather than wrapping sideways.
        guard ids.indices.contains(next) else { return move == .down && index/max(1,columns) < (ids.count-1)/max(1,columns) ? ids.last : current }
        return ids[next]
    }
}

/// Lets a cell click hand keyboard focus to the grid's key view.
@MainActor
final class GridKeys {
    fileprivate weak var view: GridKeyView?
    func focus() { if let view { view.window?.makeFirstResponder(view) } }
}

/// An invisible first responder behind the grid. It uses the standard key bindings, so
/// arrow keys and Return behave as they do in other AppKit views, and it joins the key
/// view loop, so Tab reaches the grid with Full Keyboard Access.
private struct GridKeyCatcher: NSViewRepresentable {
    let keys: GridKeys
    let move: (GridNavigation.Move) -> Void
    let open: () -> Void
    let focusChanged: (Bool) -> Void
    func makeNSView(context: Context) -> GridKeyView {
        let view=GridKeyView();keys.view=view;update(view);return view
    }
    func updateNSView(_ view: GridKeyView,context: Context) { keys.view=view;update(view) }
    private func update(_ view: GridKeyView) { view.move=move;view.open=open;view.focusChanged=focusChanged }
}

final class GridKeyView: NSView {
    var move: (GridNavigation.Move) -> Void={ _ in }
    var open: () -> Void={}
    var focusChanged: (Bool) -> Void={ _ in }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func becomeFirstResponder() -> Bool { focusChanged(true);return true }
    override func resignFirstResponder() -> Bool { focusChanged(false);return true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func moveLeft(_ sender: Any?) { move(.left) }
    override func moveRight(_ sender: Any?) { move(.right) }
    override func moveUp(_ sender: Any?) { move(.up) }
    override func moveDown(_ sender: Any?) { move(.down) }
    override func insertNewline(_ sender: Any?) { open() }
    /// Unbound keys beep in AppKit; the grid has no text, so ignore them quietly.
    override func doCommand(by selector: Selector) { if responds(to:selector) { perform(selector,with:nil) } }
}
