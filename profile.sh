#!/bin/sh

forge snapshot --diff --no-match-test ".*[F-f]uzz" --no-match-path "./test/Extsload.t.sol" --match-path "Pausable"
