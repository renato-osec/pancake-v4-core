Small arithmetic hack, the result of iszero is either 1 or 0 so the xor operator is equal to !=

Before:

flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

After:

assembly ("memory-safe") {
    flipped := xor(iszero(liquidityGrossBefore), iszero(liquidityGrossAfter))
}
