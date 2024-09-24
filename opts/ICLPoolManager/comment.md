### filename

src/pool-cl/interfaces/ICLPoolManager.sol

### summary

struct packing opt

### noted yul diff

Old:

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

New:

struct SwapParams {
    bool zeroForOne;
    uint160 sqrtPriceLimitX96;
    int256 amountSpecified;
}


