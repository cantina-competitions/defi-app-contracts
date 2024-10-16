import { MerkleTree } from "merkletreejs";

export function buildMerkleTree(
  leaves: Array<string>,
  hashFn: any
): MerkleTree {
  // NOTE: sortPairs is set to true to ensure the same tree is generated similar
  // to verification process in Openzeppelin's MerkleProof.sol
  return new MerkleTree(leaves, hashFn, { sortPairs: true });
}
