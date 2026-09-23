# Systolic tile adapter

`rtl/systolic_tile_adapter.sv` is the compute-side stream boundary. It accepts
one packed A and B tile, stores the feed vectors, invokes the existing
`systolic_array` through its documented clear/feed/drain schedule, and emits
the `N*N` signed INT32 results as a ready/valid stream.

The adapter deliberately treats word counts as authoritative instead of
requiring AXI burst `LAST` alignment. This allows it to consume streams from
the read DMA even when a matrix tile crosses burst boundaries. The runtime
tiled controller now repeats the adapter contract for each M/N/K tile; the
output stream feeds K accumulation and the ML post-processing boundary.
