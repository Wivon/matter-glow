// Pair a lamp that Apple Home has put in pairing mode.
// Usage: node pair.js <setup-code> <name>
//   e.g. node pair.js 1234-567-8901 ceiling
import { GeneralCommissioning, BasicInformation, ColorControl } from "@matter/main/clusters";
import { ManualPairingCodeCodec } from "@matter/main/types";
import { Seconds } from "@matter/main";
import { startController, connectNode } from "./lib/controller.js";
import { saveLamp } from "./lib/lamps.js";

const [code, name] = process.argv.slice(2);
if (!code || !name) {
    console.error("Usage: node pair.js <setup-code> <name>");
    process.exit(1);
}

const { shortDiscriminator, passcode } = ManualPairingCodeCodec.decode(code.replace(/[^0-9]/g, ""));
const controller = await startController({ logLevel: process.env.LOG ?? "warn" });

console.log(`Looking for the lamp on the network (discriminator ${shortDiscriminator})...`);
const nodeId = await controller.commissionNode({
    commissioning: {
        regulatoryLocation: GeneralCommissioning.RegulatoryLocationType.Indoor,
        regulatoryCountryCode: "XX",
    },
    discovery: {
        identifierData: { shortDiscriminator },
        discoveryCapabilities: { onIpNetwork: true },
        timeout: Seconds(60),
    },
    passcode,
});
console.log(`Paired as node ${nodeId}`);

const node = await connectNode(controller, nodeId);

const info = node.getRootEndpoint().getClusterClient(BasicInformation.Cluster);
const light = node.getDevices().find(d => d.getClusterClient(ColorControl.Cluster));
const color = light?.getClusterClient(ColorControl.Cluster);
console.log({
    vendor: await info.getVendorNameAttribute(),
    product: await info.getProductNameAttribute(),
    endpoint: light?.getNumber(),
    colorFeatures: color?.supportedFeatures,
});

saveLamp(name, { nodeId: nodeId.toString(), endpoint: light?.getNumber() });
console.log(`Saved as "${name}" in lamps.json`);
await controller.close();
process.exit(0);
