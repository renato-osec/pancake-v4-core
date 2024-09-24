Unneeded and

New:

// update two members in one go
assembly ("memory-safe") {
    sstore(
        info.slot, or(liquidityGrossAfter, shl(128, liquidityNetAfter))
    )
}

Old:

// update two members in one go
assembly ("memory-safe") {
    sstore(
        info.slot, or(and(liquidityGrossAfter, 0xffffffffffffffffffffffffffffffff), shl(128, liquidityNetAfter))
    )
}
