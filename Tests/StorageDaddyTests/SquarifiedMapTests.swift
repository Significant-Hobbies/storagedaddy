import Foundation
import Testing
@testable import StorageDaddy

struct SquarifiedMapTests {
    @Test func exactAreasStayInsideBoundsAndDoNotOverlap() {
        let bounds = CGRect(x: 10, y: 20, width: 900, height: 600)
        let weights = [50.0, 20, 10, 8, 7, 5]
        let result = SquarifiedMap.layout(weights: weights, in: bounds)
        #expect(result.count == weights.count)
        for (index, rect) in result.enumerated() {
            #expect(abs(rect.width * rect.height / (bounds.width * bounds.height) - weights[index] / 100) < 0.000001)
            #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect))
            for other in result.dropFirst(index + 1) {
                let overlap = rect.intersection(other)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.000001)
            }
        }
        #expect(SquarifiedMap.layout(weights: [], in: bounds).isEmpty)
        #expect(SquarifiedMap.layout(weights: [.infinity], in: bounds).isEmpty)
    }
}
