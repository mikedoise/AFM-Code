import Foundation
import Observation
import Synchronization

@Observable final class SelectionFixture {
    var selected: ModelChoice?
    var inherited: ModelChoice?
    var inFlight: ModelDescriptor?
    var descriptors: [ModelDescriptor]
    init(_ descriptors: [ModelDescriptor]) { self.descriptors = descriptors }
    var active: ModelDescriptor? {
        ModelSelectionResolver.activeModel(selected: ModelSelectionResolver.resolve(session: selected, project: inherited, descriptors: descriptors), inFlight: inFlight)
    }
}
@main struct ModelStatusTests {
    static func main() {
        let afm = ModelDescriptor(kind: .afmCore, displayName: "AFM Core", detail: nil, isAvailable: true)
        let a = ModelDescriptor(kind: .coreAI, displayName: "Gemma A", detail: nil, isAvailable: true, contextSize: 4096, coreAIModelID: "A")
        let b = ModelDescriptor(kind: .coreAI, displayName: "Gemma B", detail: nil, isAvailable: true, contextSize: 131072, coreAIModelID: "B")
        let mlx = ModelDescriptor(kind: .mlx, displayName: "MLX Model", detail: nil, isAvailable: true, mlxRepoID: "fixture/model")
        let store = SelectionFixture([afm, a, b, mlx])
        precondition(store.active == afm)
        store.inherited = .init(kind: .coreAI, coreAIID: "A")
        precondition(store.active == a)
        store.selected = .init(kind: .coreAI, coreAIID: "B")
        precondition(store.active == b)
        let observed = Mutex(false)
        withObservationTracking { _ = store.active } onChange: { observed.withLock { $0 = true } }
        store.selected = .init(kind: .mlx, mlxRepoID: "fixture/model")
        precondition(store.active == mlx && observed.withLock { $0 })
        print("PASS Automatic, project default, session override and observed selection changes")

        store.inFlight = a
        store.selected = .init(kind: .coreAI, coreAIID: "B")
        precondition(store.active == a)
        store.inFlight = nil
        precondition(store.active == b)
        print("PASS selected model can change without relabeling the in-flight model")

        store.selected = .init(kind: .coreAI, coreAIID: "removed")
        precondition(store.active?.kind == .coreAI && store.active?.isAvailable == false && store.active?.coreAIModelID == "removed")
        store.selected = .init(kind: .mlx, mlxRepoID: "removed")
        precondition(store.active == afm)
        print("PASS removed Core AI remains unavailable; existing missing-MLX fallback preserved")

        for model in [a, mlx, afm] {
            let status = ModelStatus.resolve(model: model)
            precondition(status.state == .selected && !status.accessibilityLabel.contains("Loaded"))
        }
        precondition(ModelStatus.resolve(model: a, preparing: true, failure: "old failure").state == .preparing)
        precondition(ModelStatus.resolve(model: a, inUse: true).state == .inUse)
        precondition(ModelStatus.resolve(model: a, loaded: true).state == .loaded)
        precondition(ModelStatus.resolve(model: a, loaded: true, failure: "previous request failed").state == .loaded)
        let failed = ModelStatus.resolve(model: a, loaded: false, failure: "Load failed")
        precondition(failed.state == .failed && failed.detail == "Load failed" && failed.accessibilityLabel.contains("Gemma A"))
        let missing = ModelStatus.resolve(model: nil)
        precondition(missing.state == .unavailable)
        precondition(ModelStatus.resolve(model: a, role: .projectDefault).label == "Project default")
        precondition(ModelStatus.resolve(model: afm, role: .appDefault).label == "Default")
        precondition(ModelStatus.resolve(model: b).accessibilityLabel.contains("Gemma B"))
        print("PASS selected, preparing, loaded, in-use, error, unavailable and default labels are distinct and accessible")
    }
}
