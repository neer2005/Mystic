import SwiftUI

/// What VoiceOver reads for a card, and the actions it offers besides selecting it.
struct GameCardDescription {
    var label: String
    var value: String
    var actions: [(name: String,perform: () -> Void)]=[]
}

/// The keyboard model shared by Home and the host library: arrow keys move the
/// selection, the selection scrolls into view, and Return or a double-click opens it.
/// Like Finder, the selection is drawn in the accent colour only while the grid has focus.
struct GameGrid<Item: Identifiable,Card: View,Footer: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selection: Item.ID?
    var minimumWidth: CGFloat=140
    let label: String
    /// Return and double-click; nil when the selected item cannot be opened.
    let open: (Item) -> Void
    let describe: (Item) -> GameCardDescription
    @ViewBuilder let card: (Item) -> Card
    @ViewBuilder var footer: () -> Footer
    @FocusState private var focused: Bool
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
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of:focused) { if focused,selection == nil { selection=items.first?.id } }
            .onMoveCommand { direction in
                let move: GridNavigation.Move
                switch direction { case .left:move = .left;case .right:move = .right;case .up:move = .up;case .down:move = .down;default:return }
                let ids=items.map(\.id)
                guard let next=GridNavigation.target(ids:ids,from:selection,move:move,columns:columns) else { return }
                selection=next
                withAnimation(.default) { proxy.scrollTo(next) }
            }
            .onKeyPress(.return) {
                guard let item=selectedItem else { return .ignored }
                open(item);return .handled
            }
        }
    }
    /// A selectable cell rather than a Button: a plain-style Button drops custom accessibility actions.
    private func cell(_ item: Item) -> some View {
        let selected=selection == item.id,description=describe(item)
        let select={ selection=item.id;focused=true }
        return card(item)
            .padding(8)
            .background(selected ? highlight.opacity(0.14) : Color.clear,in:RoundedRectangle(cornerRadius:10))
            .overlay { RoundedRectangle(cornerRadius:10).strokeBorder(selected ? highlight : Color.clear,lineWidth:2) }
            .contentShape(Rectangle())
            .id(item.id)
            // Both run without waiting for each other, so a single click selects at once.
            .simultaneousGesture(TapGesture().onEnded(select))
            .simultaneousGesture(TapGesture(count:2).onEnded { select();open(item) })
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
         open: @escaping (Item) -> Void,describe: @escaping (Item) -> GameCardDescription,@ViewBuilder card: @escaping (Item) -> Card) {
        self.init(items:items,selection:selection,minimumWidth:minimumWidth,label:label,open:open,describe:describe,card:card,footer:{ EmptyView() })
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
