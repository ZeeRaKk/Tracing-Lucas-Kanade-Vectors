rtlat timer --cpu 7 --policy fifo --prio 80 --duration 10m --out 1-sans-concurrent.json
rtlat timer --cpu 7 --policy fifo --prio 80 --duration 10m --load-cpus 7 --load-kind cpu --out 2-fifo.json
rtlat timer --cpu 7 --policy rr   --prio 80 --duration 10m --load-cpus 7 --load-kind cpu --out 3-rr.json
rtlat timer --cpu 7 --policy other          --duration 10m --load-cpus 7 --load-kind cpu --out 4-other.json
rtlat timer --cpu 7 --policy other          --duration 10m --load-cpus 7 --load-kind memcpy --out 5-other-memcpy.json
rtlat pingpong --cpu 7 --cpu2 8 --policy fifo --prio 80 --duration 10m --load-cpus 7-8 --load-kind cpu --out 6-pp-fifo.json
rtlat pingpong --cpu 7 --cpu2 8 --policy other          --duration 10m --load-cpus 7-8 --load-kind cpu --out 7-pp-other.json