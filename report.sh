#!/bin/sh

forge test --gas-report --no-match-test ".*[F-f]uzz" --no-match-path "./test/Extsload.t.sol"
