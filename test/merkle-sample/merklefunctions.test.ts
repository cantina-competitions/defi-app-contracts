import { expect, test } from "bun:test";
import type { BalanceInput, DistroInput } from "../../script/merkle-ts/types";
import {
  getBalanceInputLeaves,
  getBalanceInputLeave,
} from "../../script/merkle-ts/getBalanceInputLeaves";
import {
  getDistroInputLeaves,
  getDistroInputLeave,
} from "../../script/merkle-ts/getDistroInputLeaves";
import { buildMerkleTree } from "../../script/merkle-ts/buildMerkleTree";
import { default as balanceInputs } from "./balance-inputs.json";
import { default as distroInputs } from "./distro-inputs.json";
import { keccak256 } from "viem";

const DEBUG = false;
const BALANCE_MAGIC_INPUT_LEAF: BalanceInput = {
  avgBalance: "366763651904234827081373323550041817979117518910",
  boost: "366763651904234827081373323550041817979117518910",
  protocolId:
    "0x000000000000000000000000403e403e403e403e403e403e403e403e403e403e",
  timeSpanId:
    "0x000000000000000000000000403e403e403e403e403e403e403e403e403e403e",
  userId: "0x403E403e403e403e403E403E403e403e403E403E",
};
const DISTRO_MAGIC_INPUT_LEAF: DistroInput = {
  points: "366763651904234827081373323550041817979117518910",
  tokens: BigInt("366763651904234827081373323550041817979117518910"),
  userId: "0x403e403e403e403e403e403e403e403e403e403e",
};

function checkLeaves(leaves: string[]) {
  for (const leaf of leaves) {
    // Check that each leaf is a 32 byte hex string
    if (DEBUG) console.log("leaf", leaf);
    expect(leaf).toMatch(/^0x[0-9a-fA-F]{64}$/);
  }
}

test("Should check BalanceInput type data can be converted to leaves", () => {
  const balanceLeaves = getBalanceInputLeaves(
    balanceInputs as unknown[] as BalanceInput[]
  );
  expect(balanceLeaves.length).toBe(balanceInputs.length);
  checkLeaves(balanceLeaves);
});

test("Should check DistroInput type data can be converted to leaves", () => {
  const distroLeaves = getDistroInputLeaves(
    distroInputs as unknown[] as DistroInput[]
  );
  expect(distroLeaves.length).toBe(distroInputs.length);
  checkLeaves(distroLeaves);
});

test("Should check BalanceInput can be converted to MerkleTree and validate proof of MAGIC_INPUT", () => {
  const balanceLeaves = getBalanceInputLeaves(
    balanceInputs as unknown[] as BalanceInput[]
  );
  const balancesTree = buildMerkleTree(balanceLeaves, keccak256);
  const balancesRoot = balancesTree.getRoot();
  const balancesRootHex = "0x" + balancesRoot.toString("hex");
  const magicLeaf = getBalanceInputLeave(BALANCE_MAGIC_INPUT_LEAF);
  const magicProof = balancesTree.getProof(magicLeaf);
  if (DEBUG) {
    console.log("balancesTree", balancesTree.toString());
    console.log("balancesRootHex", balancesRootHex);
    console.log("magicLeaf", magicLeaf);
  }
  expect(balancesTree).toBeDefined();
  expect(balancesRootHex).toMatch(/^0x[0-9a-fA-F]{64}$/);
  expect(balancesTree.verify(magicProof, magicLeaf, balancesRoot)).toBe(true);
});

test("Should check DistroInput can be converted to MerkleTree and validate proof of MAGIC_INPUT", () => {
  const distroLeaves = getDistroInputLeaves(
    distroInputs as unknown[] as DistroInput[]
  );
  const distroTree = buildMerkleTree(distroLeaves, keccak256);
  const distroRoot = distroTree.getRoot();
  const distroRootHex = "0x" + distroRoot.toString("hex");
  const magicLeaf = getDistroInputLeave(DISTRO_MAGIC_INPUT_LEAF);
  const magicProof = distroTree.getProof(magicLeaf);
  if (DEBUG) {
    console.log("distroTree", distroTree.toString());
    console.log("distroRootHex", distroRootHex);
    console.log("magicLeaf", magicLeaf);
  }
  expect(distroTree).toBeDefined();
  expect(distroRootHex).toMatch(/^0x[0-9a-fA-F]{64}$/);
  expect(distroTree.verify(magicProof, magicLeaf, distroRoot)).toBe(true);
});
