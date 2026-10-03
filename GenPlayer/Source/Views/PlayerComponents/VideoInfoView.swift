import SwiftUI

struct VideoInfoView: View {
    @ObservedObject var playbackService: VLCPlaybackService
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                let sections = playbackService.mediaInfoSections
                let usesSplitLayout = shouldUseSplitLayout(containerWidth: geometry.size.width)
                let horizontalPadding: CGFloat = usesSplitLayout ? 20 : 16

                ScrollView {
                    if let artwork = playbackService.state.currentItem?.artwork {
                        mediaArtworkCard(image: artwork)
                            .padding(.top, 12)
                            .padding(.horizontal, horizontalPadding)
                    }

                    if usesSplitLayout {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)
                            ],
                            alignment: .leading,
                            spacing: 20
                        ) {
                            ForEach(sections) { section in
                                DarkInfoSection(title: section.title, icon: section.icon, items: section.items)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 16)
                    } else {
                        LazyVStack(spacing: 20) {
                            ForEach(sections) { section in
                                DarkInfoSection(title: section.title, icon: section.icon, items: section.items)
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 16)
                    }
                }
            }
            .background(Color(UIColor.systemBackground).ignoresSafeArea())
            .preferredColorScheme(.dark)
            .navigationTitle(NSLocalizedString("Media Info", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button(action: { presentationMode.wrappedValue.dismiss() }) {
                AppToolbarIcon(systemName: "xmark", style: .secondary)
            })
            .onAppear {
                if let url = playbackService.state.currentItem?.url,
                   VideoFile.FileType.determineType(from: url) == .audio {
                    playbackService.extractMetadata()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func mediaArtworkCard(image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 280, maxHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
            .frame(maxWidth: .infinity)
    }

    private func shouldUseSplitLayout(containerWidth: CGFloat) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && containerWidth >= 720
    }
}

struct DarkInfoSection: View {
    let title: String
    let icon: String
    let items: [(key: String, value: String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
            }
            .padding(.horizontal, 4)
            
            // Key-Value Rows
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 12) {
                        Text(items[index].key)
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 92, alignment: .leading)
                        
                        if #available(iOS 15.0, *) {
                            infoValueText(items[index].value)
                                .textSelection(.enabled)
                        } else {
                            infoValueText(items[index].value)
                        }
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 14)
                    
                    if index < items.count - 1 {
                        Divider()
                            .background(Color.white.opacity(0.1))
                            .padding(.leading, 14)
                    }
                }
            }
            .background(Color.white.opacity(0.08))
            .cornerRadius(12)
        }
    }

    private func infoValueText(_ value: String) -> some View {
        Text(value)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundColor(.white.opacity(0.9))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }
}
