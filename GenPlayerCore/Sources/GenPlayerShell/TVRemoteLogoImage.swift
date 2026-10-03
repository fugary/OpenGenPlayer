import SwiftUI

#if os(tvOS)
struct TVRemoteLogoImage: View {
    let url: URL?
    var maxHeight: CGFloat = 80
    
    @State private var image: UIImage? = nil
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: maxHeight)
                    .id(url?.absoluteString ?? "tv-remote-logo-image")
            } else {
                Color.clear
                    .frame(width: 1, height: maxHeight)
            }
        }
        .onAppear {
            load()
        }
        .onChange(of: url) { _ in
            load()
        }
    }
    
    private func load() {
        guard let url = url else {
            image = nil
            return
        }
        
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let uiImage = UIImage(data: data) {
                DispatchQueue.main.async {
                    self.image = uiImage
                }
            }
        }.resume()
    }
}
#endif
