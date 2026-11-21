#if os(macOS)
import SwiftUI

struct LogView: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).id(index)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .onChange(of: model.log.last, initial: true) { _, _ in
                    if !model.log.isEmpty { proxy.scrollTo(model.log.count - 1, anchor: .bottom) }
                }
            }
        } label: {
            HStack {
                Text("Activity").font(.headline)
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).lineLimit(1)
                } else if let last = model.log.last {
                    Text(last).lineLimit(1).help(last)
                }
            }
        }.padding(12)
    }
}
#endif
