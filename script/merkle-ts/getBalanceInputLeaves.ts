import type { BalanceInput } from "./types";
import { checksumAddress, encodePacked, keccak256 } from "viem";

export function getBalanceInputLeaves(
  data: Array<BalanceInput>
): Array<string> {
  return data.map((input) => getBalanceInputLeave(input));
}

export function getBalanceInputLeave(input: BalanceInput): string {
  return keccak256(
    encodePacked(
      ["uint256", "uint256", "bytes32", "bytes32", "address"],
      [
        BigInt(input.avgBalance),
        BigInt(input.boost),
        input.protocolId,
        input.timeSpanId,
        checksumAddress(input.userId),
      ]
    )
  );
}
