import Foundation
import Testing

@testable import ChirpCore

@Suite struct TurnGateTests {
    /// Counts how many are inside at once.
    actor Counter {
        var inside = 0
        var most = 0
        var order: [Int] = []
        func enter(_ id: Int) {
            inside += 1
            most = max(most, inside)
            order.append(id)
        }
        func leave() { inside -= 1 }
    }

    @Test func oneAtATime() async {
        let gate = TurnGate()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for id in 0..<12 {
                group.addTask {
                    await gate.enter()
                    await counter.enter(id)
                    try? await Task.sleep(for: .milliseconds(5))
                    await counter.leave()
                    gate.leave()
                }
            }
        }
        #expect(await counter.most == 1)
        #expect(await counter.order.count == 12)
        #expect(gate.queued == 0)
    }

    @Test func servedInTheOrderTheyAsked() async {
        let gate = TurnGate()
        let counter = Counter()
        await gate.enter()
        var tasks: [Task<Void, Never>] = []
        for id in 0..<5 {
            tasks.append(Task {
                await gate.enter()
                await counter.enter(id)
                await counter.leave()
                gate.leave()
            })
            // Each joins the queue before the next is started.
            while gate.queued < id + 1 { await Task.yield() }
        }
        gate.leave()
        for task in tasks { await task.value }
        #expect(await counter.order == [0, 1, 2, 3, 4])
    }

    @Test func aCancelledWaiterStillGetsItsTurnAndGivesItBack() async {
        let gate = TurnGate()
        await gate.enter()
        let waiter = Task { () -> Bool in
            await gate.enter()
            defer { gate.leave() }
            return Task.isCancelled
        }
        while gate.queued < 1 { await Task.yield() }
        waiter.cancel()
        gate.leave()
        #expect(await waiter.value)
        // The gate is free again: this returns at once.
        await gate.enter()
        gate.leave()
    }
}
