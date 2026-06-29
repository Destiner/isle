//
//  Item.swift
//  Isle
//
//  Created by Timur Badretdinov on 29/06/2026.
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
