import {
  TypedDataEncoder,
  ethers,
  parseEther,
  solidityPackedKeccak256,
} from 'ethers';

interface ITrade {
  sellTokenIndex: bigint;
  buyTokenIndex: bigint;
  receiver: string;
  sellAmount: bigint;
  buyAmount: bigint;
  validTo: number;
  appData: string;
  feeAmount: bigint;
  flags: bigint;
  executedAmount: bigint;
  signature: string;
}

interface IInteraction {
  target: string;
  value: bigint;
  callData: string;
}

interface ISettleData {
  tokens: string[];
  clearingPrices: bigint[];
  trades: ITrade[];
  preInteractions: IInteraction[];
}

const settlementTypes = {
  SettleData: [
    { type: 'address[]', name: 'tokens' },
    { type: 'uint256[]', name: 'clearingPrices' },
    { type: 'GPv2TradeData[]', name: 'trades' },
    { type: 'GPv2InteractionData[]', name: 'preInteractions' },
  ],
  GPv2TradeData: [
    { type: 'uint256', name: 'sellTokenIndex' },
    { type: 'uint256', name: 'buyTokenIndex' },
    { type: 'address', name: 'receiver' },
    { type: 'uint256', name: 'sellAmount' },
    { type: 'uint256', name: 'buyAmount' },
    { type: 'uint32', name: 'validTo' },
    { type: 'bytes32', name: 'appData' },
    { type: 'uint256', name: 'feeAmount' },
    { type: 'uint256', name: 'flags' },
    { type: 'uint256', name: 'executedAmount' },
    { type: 'bytes', name: 'signature' },
  ],
  GPv2InteractionData: [
    { type: 'address', name: 'target' },
    { type: 'uint256', name: 'value' },
    { type: 'bytes', name: 'callData' },
  ],
};

const typedDomain = {
  chainId: 1,
  name: 'SignedSettlement',
  version: '1',
  verifyingContract: '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC',
};

const TYPE_ENCODER = new TypedDataEncoder(settlementTypes);

const getTradesHash = (trades: ITrade[]): string => {
  return TYPE_ENCODER.encodeData('GPv2TradeData[]', trades);
};

const getInteractionsHash = (interactions: IInteraction[]): string => {
  return TYPE_ENCODER.encodeData('GPv2InteractionData[]', interactions);
};

const getSettleDataHash = (data: ISettleData): string => {
  return TYPE_ENCODER.hashStruct('SettleData', data);
};

const getInteractionHash = (interaction: IInteraction): string => {
  return TYPE_ENCODER.hashStruct('GPv2InteractionData', interaction);
}

// equivalent to makeAddr from forge-std
const makeAddr = (name: string) => {
  const wallet = new ethers.Wallet(solidityPackedKeccak256(['string'], [name]));
  return wallet.address;
};

const main = async () => {
  const appData =
    '0x80b560006b96ae18be8a708574995140228a3b5c6fd541d6ab937f7937280d0b';

  console.log(makeAddr('token1'));

  const testData: ISettleData = {
    tokens: [makeAddr('token1'), makeAddr('token2'), makeAddr('token3')],
    clearingPrices: [parseEther('10'), parseEther('5'), 5n * 10n ** 6n],
    trades: [
      {
        sellTokenIndex: 0n,
        buyTokenIndex: 1n,
        receiver: makeAddr('user1'),
        sellAmount: parseEther('1'),
        buyAmount: parseEther('0.5'),
        validTo: 123456,
        appData: appData,
        feeAmount: 0n,
        flags: 0x11n,
        executedAmount: parseEther('1'),
        signature:
          '0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000555555555555555555555555555555555555555555555555550',
      },
      {
        sellTokenIndex: 0n,
        buyTokenIndex: 2n,
        receiver: makeAddr('user2'),
        sellAmount: parseEther('10'),
        buyAmount: parseEther('0.3'),
        validTo: 78901234,
        appData: appData,
        feeAmount: 0n,
        flags: 0x11n,
        executedAmount: parseEther('1.5'),
        signature:
          '0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001010101010101010101010101010101010101010101010101010101010101010100000',
      },
      {
        sellTokenIndex: 2n,
        buyTokenIndex: 1n,
        receiver: makeAddr('user3'),
        sellAmount: parseEther('0.1'),
        buyAmount: parseEther('0.5'),
        validTo: 567890,
        appData: appData,
        feeAmount: 0n,
        flags: 0x11n,
        executedAmount: parseEther('1.2'),
        signature:
          '0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323230000000000',
      },
    ],
    preInteractions: [
      {
        target: makeAddr('target1'),
        value: parseEther('0.1'),
        callData:
          '0x3434343434343434343434355555555555555555555555555555555554',
      },
      {
        target: makeAddr('target2'),
        value: parseEther('12'),
        callData:
          '0x666666666666666666666666666666666666666666666666663434343434343434343434355555555555555555555555555555555554',
      },
    ],
  };
  console.log(testData);

  console.log({
    settleDataHash: getSettleDataHash(testData),
    tradesHash: getTradesHash(testData.trades),
    interactionsHash: getInteractionsHash(testData.preInteractions),
    interactionHashes: testData.preInteractions.map(x => getInteractionHash(x))
  });
};

main();
