import Foundation
import GardenKit

// One step per launch: `simctl launch --console-pty <device> <bundle> -do <step> -model <id> [-share 0]`.
// Prints "GARDEN ..." lines, then "== done". tests/e2e.sh reads them.
setvbuf(stdout, nil, _IOLBF, 0)
let args = UserDefaults.standard
let step = args.string(forKey: "do") ?? "state"
let id = args.string(forKey: "model") ?? "t-share"
let app = Bundle.main.bundleIdentifier!.components(separatedBy: ".").last!
func say(_ s: String) { print("GARDEN \(app) \(s)") }

Task {
    do {
        let group = Garden.appGroupContainer("group.io.github.stefan814.garden")
        say("GROUP \(group == nil ? "none" : "ok")")
        let catalog = try Catalog.parse(Data(contentsOf: Bundle.main.url(forResource: "test-catalog", withExtension: "json")!),
                                        allowSameFile: true)
        let g = try Garden(appID: Bundle.main.bundleIdentifier!, sharedContainer: group, catalog: catalog,
                           downloadAttempts: 2, retryDelay: .milliseconds(200))
        switch step {
        case "state": break
        case "adopt": try g.adopt(id)
        case "download": try await g.download(id, share: args.string(forKey: "share") != "0")
        case "remove": try g.remove(id)
        case "open":
            let m = try g.open(id)
            for f in m.model.files {
                let data = try Data(contentsOf: m.url(f.name))
                say("OPEN \(f.name) bytes=\(data.count) tier=\(m.tier)")
            }
        default: say("ERROR unknown step \(step)")
        }
        say("STATE \(id) = \(try g.state(id))")
        say("HOLDERS \(try g.holders(id).sorted().map { $0.components(separatedBy: ".").last! }.joined(separator: ","))")
    } catch {
        say("ERROR \(error.localizedDescription)")
    }
    say("== done")
    exit(0)
}
dispatchMain()
