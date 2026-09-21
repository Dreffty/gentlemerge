import XCTest
@testable import GentleMergeCore

final class UnfinishedWorkTests: XCTestCase {
    private func handoff(_ tasks: [TaskItem]) -> ProjectHandoff {
        ProjectHandoff(projectPath: "/tmp/gameapp", projectName: "gameapp", tasks: tasks)
    }

    func testATaskLeftHalfWayIsWorthTelling() throws {
        let notice = try XCTUnwrap(UnfinishedWork.notice(for: handoff([
            TaskItem(text: "Smoke manual de tipos de habito", steps: [
                TaskStep(text: "contable 3 taps", done: true),
                TaskStep(text: "timer 5 min"),
                TaskStep(text: "reto semanal"),
            ]),
        ])))

        XCTAssertEqual(notice.startedCount, 1)
        XCTAssertEqual(notice.openStepCount, 2)
        XCTAssertTrue(notice.title.contains("gameapp"), "which project it was")
        XCTAssertTrue(notice.summary.contains("1/3"))
        XCTAssertTrue(notice.detail.contains("- [ ] timer 5 min"))
        XCTAssertFalse(notice.detail.contains("contable"), "what got done is not the news")
        XCTAssertTrue(notice.detail.contains("HANDOFF.md"), "where the rest of it is")
    }

    func testNothingIsSaidWhenThereIsNothingToSay() {
        XCTAssertNil(UnfinishedWork.notice(for: handoff([])))
        XCTAssertNil(
            UnfinishedWork.notice(for: handoff([TaskItem(text: "no points here")])),
            "a task nobody broke down cannot be half done"
        )
        XCTAssertNil(
            UnfinishedWork.notice(for: handoff([
                TaskItem(text: "all of it", steps: [TaskStep(text: "one", done: true)]),
            ])),
            "every point ticked is a finished task"
        )
    }

    func testWhatSomebodyStartedComesBeforeWhatNobodyTouched() throws {
        let notice = try XCTUnwrap(UnfinishedWork.notice(for: handoff([
            TaskItem(text: "only planned", steps: [TaskStep(text: "a"), TaskStep(text: "b")]),
            TaskItem(text: "half done", steps: [TaskStep(text: "c", done: true), TaskStep(text: "d")]),
        ])))

        XCTAssertEqual(notice.startedCount, 1)
        XCTAssertEqual(notice.openStepCount, 3)
        XCTAssertTrue(notice.summary.hasPrefix("2 tasks"))
        XCTAssertTrue(notice.detail.hasPrefix("1/2 half done"), "the abandoned one is what you want to read first")
    }

    func testALongListIsCountedRatherThanRecited() throws {
        let tasks = (1...5).map { number in
            TaskItem(
                text: "task \(number)",
                steps: (1...8).map { TaskStep(text: "point \(number).\($0)") }
            )
        }

        let notice = try XCTUnwrap(UnfinishedWork.notice(for: handoff(tasks)))

        XCTAssertEqual(notice.openStepCount, 40)
        XCTAssertTrue(notice.detail.contains("…and 4 more"), "8 points listed \(UnfinishedWork.stepPreviewLimit) at a time")
        XCTAssertTrue(notice.detail.contains("…and 2 more tasks"))
        XCTAssertFalse(notice.detail.contains("task 4"))
    }
}
