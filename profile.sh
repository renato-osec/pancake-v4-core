#!/bin/sh

forge snapshot --isolate --diff --no-match-test ".*[F-f]uzz" --no-match-path "./test/Extsload.t.sol"
