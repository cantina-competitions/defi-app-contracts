import type { DistroInput } from "./types";
import { keccak256, encodePacked } from "viem";

export function getDistroInputLeaves(data: Array<DistroInput>): Array<string> {
  return data.map((input) => getDistroInputLeave(input));
}

export function getDistroInputLeave(input: DistroInput): string {
  return keccak256(
    encodePacked(
      ["uint256", "uint256", "address"],
      [BigInt(input.points), BigInt(input.tokens), input.userId]
    )
  );
}
