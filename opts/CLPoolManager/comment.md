switched the conditions in :

if (paused() && params.liquidityDelta > 0) revert PoolPaused();

to better leverage shortcircuiting. Put the less costly and more likely condition first
