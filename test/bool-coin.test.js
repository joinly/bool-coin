import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";
import { readFileSync } from "node:fs";
import solc from "solc";
import ganache from "ganache";
import { ethers } from "ethers";

const source = readFileSync(new URL("../contracts/BoolCoin.sol", import.meta.url), "utf8");
const input = {
  language: "Solidity",
  sources: { "BoolCoin.sol": { content: source } },
  settings: {
    evmVersion: "paris",
    optimizer: { enabled: true, runs: 200 },
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } }
  }
};

const output = JSON.parse(solc.compile(JSON.stringify(input)));
if (output.errors) {
  const fatal = output.errors.filter((error) => error.severity === "error");
  if (fatal.length) {
    throw new Error(fatal.map((error) => error.formattedMessage).join("\n"));
  }
}

const contracts = output.contracts["BoolCoin.sol"];
const parse = ethers.parseEther;

let provider;
let accounts;
let owner;
let treasury;
let alice;
let bob;
let carol;
let dave;
let eve;
let usdt;
let boolToken;
let priceKeeper;
let vault;
let genesisNft;
let nodeNft;
let goldCardNft;
let ledger;
let purchase;
let rewardPool;

function factory(name, signer) {
  const contract = contracts[name];
  return new ethers.ContractFactory(contract.abi, contract.evm.bytecode.object, signer);
}

async function deploy(name, signer, args = []) {
  const instance = await factory(name, signer).deploy(...args);
  await instance.waitForDeployment();
  return instance;
}

async function mined(txPromise) {
  const tx = await txPromise;
  await tx.wait();
}

async function setup() {
  provider = new ethers.BrowserProvider(
    ganache.provider({
      logging: { quiet: true },
      wallet: { totalAccounts: 80, defaultBalance: 1000 }
    })
  );
  accounts = await provider.listAccounts();
  [owner, treasury, alice, bob, carol, dave, eve] = accounts;

  usdt = await deploy("MockUSDT", owner);
  boolToken = await deploy("BOOLToken", owner, [await usdt.getAddress(), await treasury.getAddress()]);
  priceKeeper = await deploy("PriceKeeper", owner);
  vault = await deploy("RewardVault", owner, [await usdt.getAddress()]);
  genesisNft = await deploy("ProjectNFT", owner, ["BOOL Genesis NFT", "BGEN", 30]);
  nodeNft = await deploy("ProjectNFT", owner, ["BOOL Node NFT", "BNODE", 3000]);
  goldCardNft = await deploy("ProjectNFT", owner, ["BOOL Gold Card", "BGOLD", 100]);
  ledger = await deploy("PositionLedger", owner);
  purchase = await deploy("PurchaseManager", owner, [
    await usdt.getAddress(),
    await boolToken.getAddress(),
    await genesisNft.getAddress(),
    await nodeNft.getAddress(),
    await goldCardNft.getAddress(),
    await ledger.getAddress(),
    await vault.getAddress(),
    await treasury.getAddress()
  ]);
  rewardPool = await deploy("RewardPool", owner, [await vault.getAddress()]);
  await rewardPool.connect(owner).setNftContracts(await genesisNft.getAddress(), await goldCardNft.getAddress());

  await genesisNft.connect(owner).setMinter(await purchase.getAddress(), true);
  await nodeNft.connect(owner).setMinter(await purchase.getAddress(), true);
  await goldCardNft.connect(owner).setMinter(await purchase.getAddress(), true);
  await ledger.connect(owner).setAuthorized(await purchase.getAddress(), true);
  await ledger.connect(owner).setRewardVault(await vault.getAddress());
  await vault.connect(owner).setAuthorized(await purchase.getAddress(), true);
  await vault.connect(owner).setAuthorized(await ledger.getAddress(), true);
  await vault.connect(owner).setAuthorized(await rewardPool.getAddress(), true);
  await boolToken.connect(owner).setPriceKeeper(await priceKeeper.getAddress());
  await boolToken.connect(owner).setOpenPriceDay(1);
  await boolToken.connect(owner).setCostManager(await purchase.getAddress(), true);
  await boolToken.connect(owner).transfer(await purchase.getAddress(), parse("1000000"));

  for (const account of accounts.slice(2)) {
    await usdt.connect(owner).mint(await account.getAddress(), parse("1000000"));
    await usdt.connect(account).approve(await purchase.getAddress(), ethers.MaxUint256);
    await usdt.connect(account).approve(await boolToken.getAddress(), ethers.MaxUint256);
  }
}

beforeEach(setup);

test("节点购买生成NFT、3倍仓位和100U一次性白名单额度", async () => {
  await purchase.connect(alice).buyNode(ethers.ZeroAddress);

  assert.equal(await nodeNft.balanceOf(await alice.getAddress()), 1n);
  assert.equal(await purchase.boughtNode(await alice.getAddress()), true);
  assert.equal(await purchase.whitelistAvailable(await alice.getAddress()), true);

  const positions = await ledger.userPositions(await alice.getAddress());
  const position = await ledger.positions(positions[0]);
  assert.equal(position.principal, parse("200"));
  assert.equal(position.cap, parse("600"));

  await purchase.connect(alice).whitelistBuyBool(parse("100"));
  assert.equal(await purchase.whitelistUsed(await alice.getAddress()), true);
  assert.equal(await boolToken.balanceOf(await alice.getAddress()), parse("100"));
  assert.equal(await boolToken.trackedBoolBalance(await alice.getAddress()), parse("100"));
  assert.equal(await boolToken.trackedUsdtCost(await alice.getAddress()), parse("100"));

  await assert.rejects(purchase.connect(alice).whitelistBuyBool(parse("1")));
});

test("第二阶段最小闭环：节点购买、3倍仓位、收益入账、用户领取、前台查询", async () => {
  await purchase.connect(alice).buyNode(ethers.ZeroAddress);
  const positions = await ledger.userPositions(await alice.getAddress());
  const positionId = positions[0];

  await usdt.connect(owner).mint(await vault.getAddress(), parse("600"));
  await ledger.connect(owner).releaseToVault(positionId, parse("250"), 2);
  await ledger.connect(owner).releaseToVault(positionId, parse("500"), 2);

  const details = await ledger.userPositionDetails(await alice.getAddress());
  assert.equal(details.length, 1);
  assert.equal(details[0].released, parse("600"));
  assert.equal(details[0].closed, true);
  assert.equal(await vault.pendingRewards(await alice.getAddress(), 2), parse("600"));

  const snapshot = await purchase.userSnapshot(await alice.getAddress());
  assert.equal(snapshot.boughtNode, true);
  assert.equal(snapshot.whitelistAvailable, true);
  assert.equal(snapshot.nodeBalance, 1n);

  const before = await usdt.balanceOf(await alice.getAddress());
  await vault.connect(alice).claim(2);
  const after = await usdt.balanceOf(await alice.getAddress());
  assert.equal(after - before, parse("600"));

  await assert.rejects(ledger.connect(owner).releaseToVault(positionId, parse("1"), 2));
});

test("创世推荐节点奖励35%，节点推荐节点奖励20%，均进入待领取USDT", async () => {
  await purchase.connect(alice).buyGenesis(ethers.ZeroAddress);
  await purchase.connect(bob).buyNode(await alice.getAddress());

  assert.equal(
    await vault.pendingRewards(await alice.getAddress(), 1),
    parse("70")
  );

  await purchase.connect(carol).buyNode(await bob.getAddress());
  assert.equal(
    await vault.pendingRewards(await bob.getAddress(), 1),
    parse("40")
  );

  const before = await usdt.balanceOf(await bob.getAddress());
  await vault.connect(bob).claim(1);
  const after = await usdt.balanceOf(await bob.getAddress());
  assert.equal(after - before, parse("40"));
});

test("静态入金生成2倍仓位，节点推荐静态奖励20%，并计入团队业绩", async () => {
  await purchase.connect(alice).buyNode(ethers.ZeroAddress);
  await purchase.connect(bob).staticDeposit(parse("1000"), await alice.getAddress());

  assert.equal(await vault.pendingRewards(await alice.getAddress(), 1), parse("200"));
  assert.equal(await purchase.teamPerformance(await alice.getAddress()), parse("1000"));

  const positions = await ledger.userPositions(await bob.getAddress());
  const position = await ledger.positions(positions[0]);
  assert.equal(position.principal, parse("1000"));
  assert.equal(position.cap, parse("2000"));
});

test("第三阶段：创世、静态、金卡资格和团队业绩统计可查询", async () => {
  await purchase.connect(alice).buyGenesis(ethers.ZeroAddress);
  await purchase.connect(alice).buyGenesis(ethers.ZeroAddress);
  await purchase.connect(bob).buyNode(await alice.getAddress());
  await purchase.connect(carol).buyNode(await bob.getAddress());
  await purchase.connect(dave).staticDeposit(parse("1000"), await bob.getAddress());

  const alicePositions = await ledger.userPositionDetails(await alice.getAddress());
  assert.equal(alicePositions.length, 2);
  assert.equal(await genesisNft.balanceOf(await alice.getAddress()), 2n);

  const aliceDirects = await purchase.directReferralsOf(await alice.getAddress());
  const bobDirects = await purchase.directReferralsOf(await bob.getAddress());
  assert.deepEqual(Array.from(aliceDirects), [await bob.getAddress()]);
  assert.deepEqual(Array.from(bobDirects), [await carol.getAddress(), await dave.getAddress()]);

  const aliceTeam = await purchase.teamSnapshot(await alice.getAddress());
  assert.equal(aliceTeam.personalPerformance, parse("12000"));
  assert.equal(aliceTeam.userPerformance, parse("1400"));
  assert.equal(aliceTeam.areaPerformance, parse("13400"));
  assert.equal(aliceTeam.directTotalPerformance, parse("1400"));
  assert.equal(aliceTeam.directReferralCount, 1n);
  assert.equal(aliceTeam.directNodeCount, 1n);

  const bobTeam = await purchase.teamSnapshot(await bob.getAddress());
  assert.equal(bobTeam.personalPerformance, parse("200"));
  assert.equal(bobTeam.userPerformance, parse("1200"));
  assert.equal(bobTeam.areaPerformance, parse("1400"));
  assert.equal(bobTeam.directTotalPerformance, parse("1200"));
  assert.equal(bobTeam.directReferralCount, 2n);
  assert.equal(bobTeam.directNodeCount, 1n);

  const bobSnapshot = await purchase.userSnapshot(await bob.getAddress());
  assert.equal(bobSnapshot.eligibleGoldCards, 0n);
  assert.equal(bobSnapshot.areaPerformance, parse("1400"));
  assert.equal(bobSnapshot.directTotalPerformance, parse("1200"));
});

test("每30个直推有效节点NFT可铸造1张金卡，总量受限", async () => {
  await purchase.connect(alice).buyNode(ethers.ZeroAddress);

  for (let i = 7; i < 37; i++) {
    const buyer = accounts[i];
    await purchase.connect(buyer).buyNode(await alice.getAddress());
  }

  assert.equal(await purchase.directNodeCount(await alice.getAddress()), 30n);
  assert.equal(await purchase.eligibleGoldCards(await alice.getAddress()), 1n);
  const snapshot = await purchase.userSnapshot(await alice.getAddress());
  assert.equal(snapshot.eligibleGoldCards, 1n);
  await (await purchase.connect(alice).mintGoldCard()).wait();
  assert.equal(await goldCardNft.balanceOf(await alice.getAddress()), 1n);

  await assert.rejects(async () => {
    const tx = await purchase.connect(alice).mintGoldCard();
    await tx.wait();
  });
});

test("BOOL买税、跌幅卖税和盈利税按加权均价计算", async () => {
  const pair = await dave.getAddress();
  await mined(boolToken.connect(owner).setAmmPair(pair, true));
  await mined(boolToken.connect(owner).transfer(pair, parse("10000")));
  await mined(priceKeeper.connect(owner).setDailyOpenPrice(1, parse("1")));

  await mined(priceKeeper.connect(owner).setCurrentPrice(parse("1")));
  await mined(boolToken.connect(dave).transfer(await alice.getAddress(), parse("1000")));
  assert.equal(await boolToken.balanceOf(await alice.getAddress()), parse("950"));

  await mined(priceKeeper.connect(owner).setCurrentPrice(parse("2")));
  await mined(boolToken.connect(dave).transfer(await alice.getAddress(), parse("1000")));
  assert.equal(await boolToken.balanceOf(await alice.getAddress()), parse("1900"));
  assert.equal(await boolToken.trackedBoolBalance(await alice.getAddress()), parse("1900"));
  assert.equal(await boolToken.trackedUsdtCost(await alice.getAddress()), parse("2850"));
  assert.equal(await boolToken.buyTaxBoolAccrued(), parse("100"));

  await mined(priceKeeper.connect(owner).setCurrentPrice(parse("0.89")));
  assert.equal(await boolToken.currentSellTaxBps(), 1500n);

  const taxBefore = await usdt.balanceOf(await treasury.getAddress());
  await mined(boolToken.connect(alice).transfer(pair, parse("100")));
  const taxAfter = await usdt.balanceOf(await treasury.getAddress());

  // 成本均价为1.5U，0.89U卖出无盈利税，只收15% BOOL卖税。
  assert.equal(taxAfter - taxBefore, 0n);
  assert.equal(await boolToken.balanceOf(pair), parse("8085"));
  assert.equal(await boolToken.sellTaxBoolAccrued(), parse("15"));

  await mined(priceKeeper.connect(owner).setCurrentPrice(parse("3")));
  await mined(usdt.connect(alice).approve(await boolToken.getAddress(), ethers.MaxUint256));
  const profitTaxBefore = await usdt.balanceOf(await treasury.getAddress());
  await mined(boolToken.connect(alice).transfer(pair, parse("100")));
  const profitTaxAfter = await usdt.balanceOf(await treasury.getAddress());
  assert.equal(profitTaxBefore, taxAfter);
  assert.equal(profitTaxAfter - profitTaxBefore, parse("37.5"));
  assert.equal(await boolToken.sellTaxBoolAccrued(), parse("20"));
  assert.equal(await boolToken.profitLpUsdtAccrued(), parse("30"));
  assert.equal(await boolToken.profitCommunityUsdtAccrued(), parse("7.5"));
});

test("内部奖励池每小时通缩0.25%，按20/25/50/5分配", async () => {
  await rewardPool.connect(owner).addInternalBool(parse("10000"));
  await rewardPool.connect(owner).executeHourlyDeflation(parse("2"));

  assert.equal(await rewardPool.internalBoolPool(), parse("9975"));
  assert.equal(await rewardPool.burnedBool(), parse("6.25"));
  assert.equal(await rewardPool.genesisUsdtAccrued(), parse("10"));
  assert.equal(await rewardPool.lpUsdtAccrued(), parse("25"));
  assert.equal(await rewardPool.goldUsdtAccrued(), parse("2.5"));

  await usdt.connect(owner).mint(await vault.getAddress(), parse("100"));
  await rewardPool.connect(owner).creditCategoryReward(await alice.getAddress(), 3, parse("5"));
  await vault.connect(alice).claim(3);
  assert.equal(await usdt.balanceOf(await alice.getAddress()), parse("1000005"));
});

test("第五阶段：通缩池收益按创世、LP和金卡份额进入待领取余额", async () => {
  await purchase.connect(alice).buyGenesis(ethers.ZeroAddress);
  await purchase.connect(alice).buyGenesis(ethers.ZeroAddress);
  await purchase.connect(bob).buyGenesis(ethers.ZeroAddress);
  await goldCardNft.connect(owner).mint(await alice.getAddress());
  await goldCardNft.connect(owner).mint(await bob.getAddress());
  await rewardPool.connect(owner).setLpStake(await alice.getAddress(), parse("300"));
  await rewardPool.connect(owner).setLpStake(await bob.getAddress(), parse("100"));

  await rewardPool.connect(owner).addInternalBool(parse("10000"));
  await rewardPool.connect(owner).executeHourlyDeflation(parse("2"));

  assert.equal(await rewardPool.pendingGenesisReward(await alice.getAddress()), parse("6.666666666666666666"));
  assert.equal(await rewardPool.pendingGenesisReward(await bob.getAddress()), parse("3.333333333333333333"));
  assert.equal(await rewardPool.pendingLpReward(await alice.getAddress()), parse("18.75"));
  assert.equal(await rewardPool.pendingLpReward(await bob.getAddress()), parse("6.25"));
  assert.equal(await rewardPool.pendingGoldReward(await alice.getAddress()), parse("1.25"));
  assert.equal(await rewardPool.pendingGoldReward(await bob.getAddress()), parse("1.25"));

  await usdt.connect(owner).mint(await vault.getAddress(), parse("100"));
  await rewardPool.connect(alice).claimGenesisReward();
  await rewardPool.connect(alice).claimLpReward();
  await rewardPool.connect(alice).claimGoldReward();

  assert.equal(await vault.pendingRewards(await alice.getAddress(), 2), parse("6.666666666666666666"));
  assert.equal(await vault.pendingRewards(await alice.getAddress(), 3), parse("18.75"));
  assert.equal(await vault.pendingRewards(await alice.getAddress(), 4), parse("1.25"));

  const before = await usdt.balanceOf(await alice.getAddress());
  await vault.connect(alice).claim(2);
  await vault.connect(alice).claim(3);
  await vault.connect(alice).claim(4);
  const after = await usdt.balanceOf(await alice.getAddress());
  assert.equal(after - before, parse("26.666666666666666666"));
});
