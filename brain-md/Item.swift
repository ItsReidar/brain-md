//
//  Item.swift
//  brain-md
//
//  Created by Veroft Reidar on 17/09/2026.
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
