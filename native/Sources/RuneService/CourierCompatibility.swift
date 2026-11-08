// INPUT: Explicit candidate helper and private courier state.
// OUTPUT: Read-only schema/protocol compatibility checks for maintenance.
// POS: Runtime boundary; see native/README.md.
import Foundation
import CourierCore
import RuneCore

public enum CourierRuntimeCompatibility {
    public static func pauseForUninstall(directory:URL,mock:Bool) throws {
        let store=try FileCourierStore(directory:directory)
        guard try store.read() != nil else { return }
        let engine=try CourierEngine(store:store,allowedBundleIDs:mock
            ? ["local.reset-rune.mock.codex","local.reset-rune.mock.claude"]
            : ["com.openai.codex","com.anthropic.claudefordesktop"])
        try engine.setEnabled(false)
    }
    public static func validateState(directory:URL) throws {
        let file=directory.appendingPathComponent("courier/state.json")
        if let object=try PrivateFiles.read(file) {
            try CourierEngine.validate(JSONSerialization.data(withJSONObject:object))
        }
    }
    public static func checkCandidate(_ executable:URL,directory:URL) throws {
        guard try PrivateFiles.read(directory.appendingPathComponent("courier/state.json")) != nil else { return }
        let data:Data
        do { data=try NativeRuntime.run(executable.path,["--courier-capabilities"],timeout:3) }
        catch { throw RuneError("courier-incompatible-runtime") }
        guard let response=try? JSONSerialization.jsonObject(with:data) as? JSONObject,
              response["courierProtocol"] as? Int == 1,response["schema"] as? Int == 1 else {
            throw RuneError("courier-incompatible-runtime")
        }
    }
}
