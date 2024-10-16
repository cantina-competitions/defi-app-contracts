import { MerkleTree } from "merkletreejs";

export function buildMerkleTree(
  leaves: Array<string>,
  hashFn: any
): MerkleTree {
  return new MerkleTree(leaves, hashFn);
}
