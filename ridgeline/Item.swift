//
//  Item.swift
//  ridgeline
//
//  Created by ginsan on 2026/8/10.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
