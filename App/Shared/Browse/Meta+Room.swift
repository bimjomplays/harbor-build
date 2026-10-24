import SwiftUI
import os

extension Meta {
    init(continue c: ContinueItem) {
        // A local resume entry can carry "" for art it had none for; nil lets the
        // hero, the tile and the Detail backdrop fall back to the other picture.
        let poster: String? = (c.poster ?? "").isEmpty ? nil : c.poster
        let background: String? = (c.background ?? "").isEmpty ? nil : c.background
        let logo: String? = (c.logo ?? "").isEmpty ? nil : c.logo
        self.init(id: c.id, type: c.type, name: c.name, poster: poster, background: background, logo: logo,
                  description: nil, releaseInfo: nil, releaseDate: nil, inTheaters: nil, imdbRating: nil, tmdbScore: nil,
                  runtime: nil, genres: nil, adult: nil, isCollection: nil, providerBadge: nil, videos: nil)
    }
}
