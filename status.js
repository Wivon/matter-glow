// Print the paired lamps and their current state.
import { BasicInformation } from "@matter/main/clusters";
import { NodeId } from "@matter/main/types";
import { startController, connectNode } from "./lib/controller.js";
import { connectLamps } from "./lib/lamp-control.js";
import { loadLamps } from "./lib/lamps.js";

const c = await startController({ logLevel: "error" });
const lamps = await connectLamps(c);
for (const lamp of lamps) {
    const node = await connectNode(c, NodeId(BigInt(loadLamps()[lamp.name].nodeId)));
    const info = node.getRootEndpoint().getClusterClient(BasicInformation.Cluster);
    console.log(lamp.name, {
        product: info.getProductNameAttributeFromCache(),
        firmware: info.getSoftwareVersionStringAttributeFromCache(),
        on: lamp.onOff.getOnOffAttributeFromCache(),
        level: lamp.level.getCurrentLevelAttributeFromCache(),
        colorMode: lamp.color.getColorModeAttributeFromCache(),
    });
}
await c.close();
process.exit(0);
