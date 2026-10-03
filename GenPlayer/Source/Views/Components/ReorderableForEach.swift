import SwiftUI
import UniformTypeIdentifiers

public struct ReorderableForEach<Item: Identifiable & Equatable, Content: View, Preview: View>: View {
    
    @Binding var items: [Item]
    @Binding var pickingID: Item.ID? // The item currently picked up (no opacity change yet)
    @Binding var activeID: Item.ID?  // The item officially moving (triggers 0.5 opacity)
    @ViewBuilder let content: (Item, Bool) -> Content
    @ViewBuilder let preview: (Item) -> Preview
    let onComplete: () -> Void
    
    public init(
        items: Binding<[Item]>,
        pickingID: Binding<Item.ID?>,
        activeID: Binding<Item.ID?>,
        @ViewBuilder content: @escaping (Item, Bool) -> Content,
        @ViewBuilder preview: @escaping (Item) -> Preview,
        onComplete: @escaping () -> Void
    ) {
        self._items = items
        self._pickingID = pickingID
        self._activeID = activeID
        self.content = content
        self.preview = preview
        self.onComplete = onComplete
    }
    
    public init(
        items: Binding<[Item]>,
        pickingID: Binding<Item.ID?>,
        activeID: Binding<Item.ID?>,
        @ViewBuilder content: @escaping (Item, Bool) -> Content,
        onComplete: @escaping () -> Void
    ) where Preview == EmptyView {
        self._items = items
        self._pickingID = pickingID
        self._activeID = activeID
        self.content = content
        self.preview = { _ in EmptyView() }
        self.onComplete = onComplete
    }
    
    public var body: some View {
        ForEach(items) { item in
            let isItemDragged = activeID == item.id
            
            Group {
                if Preview.self == EmptyView.self {
                    content(item, isItemDragged)
                        .onDrag {
                            self.pickingID = item.id
                            return NSItemProvider(object: "\(item.id)" as NSString)
                        }
                } else {
                    if #available(iOS 15.0, *) {
                        content(item, isItemDragged)
                            .onDrag {
                                self.pickingID = item.id
                                return NSItemProvider(object: "\(item.id)" as NSString)
                            } preview: {
                                preview(item)
                            }
                    } else {
                        // Fallback for iOS 14
                        content(item, isItemDragged)
                            .onDrag {
                                self.pickingID = item.id
                                return NSItemProvider(object: "\(item.id)" as NSString)
                            }
                    }
                }
            }
            .id(item.id) // Solid Identity for stability
            .onDrop(of: [UTType.plainText], delegate: ReorderableDropDelegate(
                item: item,
                items: $items,
                pickingID: $pickingID,
                activeID: $activeID,
                onComplete: onComplete
            ))
        }
    }
}

struct ReorderableDropDelegate<Item: Identifiable & Equatable>: DropDelegate {
    let item: Item
    @Binding var items: [Item]
    @Binding var pickingID: Item.ID?
    @Binding var activeID: Item.ID?
    let onComplete: () -> Void
    
    func dropEntered(info: DropInfo) {
        // Activate (dim) the item only when it starts moving/interacting
        if let pid = pickingID {
            if activeID == nil {
                print("DEBUG: ACTIVATING -> Displacement detected for \(pid)")
                activeID = pid
            }
        }
        
        guard let activeID = activeID, activeID != item.id else { return }
        
        if let from = items.firstIndex(where: { $0.id == activeID }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            
            if items[to].id != activeID {
                withAnimation {
                    items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                }
            }
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let pid = pickingID, activeID == nil {
            activeID = pid
        }
        return DropProposal(operation: .move)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        // Reset everything
        self.activeID = nil
        self.pickingID = nil
        onComplete()
        return true
    }
    
    func dropExited(info: DropInfo) {}
}
