# Elevation data notice

RidgeLine bundles the following elevation tile and temporarily caches additional
route-area tiles from the same source:

| Tile | Coverage | Format | Uncompressed bytes | SHA-256 |
|---|---|---|---:|---|
| `N31E102.hgt` | 31–32°N, 102–103°E (四姑娘山、双桥沟) | Skadi HGT, 3601×3601, big-endian signed Int16 | 25,934,402 | `db8efaaee8304612b569b27dfe41c298cb05b17d0ae6cdc57c32bc2d0f9bc699` |

## Source and attribution

- Downloaded on 2026-08-11 from [Mapzen Terrain Tiles on AWS Open Data](https://registry.opendata.aws/terrain-tiles/): `https://s3.amazonaws.com/elevation-tiles-prod/skadi/N31/N31E102.hgt.gz`.
- Downloaded gzip SHA-256: `37a093bfa6a241af205cba2cda0983bd7c798761615fac2062fbc4ef8fe54d32` (18,632,002 bytes). The source does not publish a per-object checksum, so this is a local reproducibility manifest rather than an upstream signature.
- Mapzen Terrain Tiles are a composite elevation product. SRTM is the primary high-resolution source for this coverage, but this notice does not claim that every cell is an unmodified LP DAAC SRTMGL1 V003 sample.
- SRTM data courtesy of the U.S. Geological Survey. Reference dataset DOI: [10.5067/MEaSUREs/SRTM/SRTMGL1.003](https://doi.org/10.5067/MEASURES/SRTM/SRTMGL1.003).
- Mapzen source-provenance documentation: [Terrain Tiles data sources](https://github.com/tilezen/joerd/blob/master/docs/data-sources.md).
- Format reference: [NASA/USGS SRTM Collection User Guide](https://lpdaac.usgs.gov/documents/179/SRTM_User_Guide_V3.pdf).
- Data-use guidance: [NASA Earthdata Data Use and Citation Guidance](https://www.earthdata.nasa.gov/engage/open-data-services-software/data-use-policy).

Acknowledgement does not imply endorsement by NASA, USGS, AWS, or Mapzen.

## Temporary route cache

- Missing tiles along a planned route are downloaded automatically; route display does not wait for elevation.
- A zoom-9 Terrarium overview (roughly 200–300 m in China) loads first, then Skadi HGT upgrades the route to 1 arc-second (~30 m) sampling.
- The UI labels the active result as overview or fine elevation; overview values are replaced when complete fine tiles become available.
- Map zoom selects the presentation automatically: regional views use overview elevation, while spans at or below 1.5° use fine elevation when available; hysteresis avoids rapid switching near the threshold.
- Files are stored in the system Caches directory, not Documents, and may also be evicted by iOS.
- The app removes files older than 30 days and applies a 500 MiB LRU-style size limit.
- Clearing or reinstalling the app removes the downloaded elevation cache. The bundled `N31E102` tile remains available.

## Reproducible verification

```sh
curl -fL -o N31E102.hgt.gz \
  https://s3.amazonaws.com/elevation-tiles-prod/skadi/N31/N31E102.hgt.gz
shasum -a 256 N31E102.hgt.gz
gzip -t N31E102.hgt.gz
gunzip -k N31E102.hgt.gz
stat -f '%z' N31E102.hgt
shasum -a 256 N31E102.hgt
```

Known samples used by the bundled-resource regression test:

| Coordinate | Elevation |
|---|---:|
| 31.10°N, 102.90°E | 5,257 m |
| 31.05°N, 102.85°E | 4,687 m |
| 31.20°N, 102.80°E | 4,342 m |
| 31.15°N, 102.95°E | 4,503 m |
