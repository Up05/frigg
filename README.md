# Ulang

# Small value syntax

Printing of small values is designed to be obvious and short.

Weirder cases:
```
..          skipping elements
..<LEN      skipping and here is the entire length
[:NUM]      the array is sliced via frigg.link(array, &new_max_length)
[0*LEN]     the array is filled with zeroes (surprisingly common)
(TYPE)      union's active variant
<self>      a pointer to a pointer to a... 16+ times over
```


```

```

