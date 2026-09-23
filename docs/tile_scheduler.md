# Runtime tile scheduler

`tile_scheduler` accepts matrix dimensions and tile dimensions at job start.
It emits one tile descriptor at a time and waits for `tile_done` before
advancing. K advances first, allowing the accumulator to retain a partial C
tile. `tile_first_k` and `tile_last_k` identify overwrite versus accumulate
and final-output behavior.

Edge tiles are clipped to the remaining M/N/K dimensions. A downstream buffer
or adapter zero-pads the clipped tile to the physical array shape.
