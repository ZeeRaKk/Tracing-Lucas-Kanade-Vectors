rtlat timer --cpu 7 --policy fifo --prio 80 --duration 10m --out 1-sans-concurrent.json
rtlat timer --cpu 7 --policy fifo --prio 80 --duration 10m --load-cpus 7 --load-kind cpu --out 2-fifo.json
rtlat timer --cpu 7 --policy rr   --prio 80 --duration 10m --load-cpus 7 --load-kind cpu --out 3-rr.json
rtlat timer --cpu 7 --policy other          --duration 10m --load-cpus 7 --load-kind cpu --out 4-other.json
rtlat timer --cpu 7 --policy other          --duration 10m --load-cpus 7 --load-kind memcpy --out 5-other-memcpy.json
rtlat pingpong --cpu 7 --cpu2 8 --policy fifo --prio 80 --duration 10m --load-cpus 7-8 --load-kind cpu --out 6-pp-fifo.json
rtlat pingpong --cpu 7 --cpu2 8 --policy other          --duration 10m --load-cpus 7-8 --load-kind cpu --out 7-pp-other.json


python3 rtlat_plot.py 1-sans-concurrent.json 2-fifo.json 3-rr.json 4-other.json 5-other-memcpy.json \
  --labels "sans concurrent,fifo,rr,other,other memcpy" -o rt-vs-non-rt.png
python3 rtlat_plot.py 6-pp-fifo.json 7-pp-other.json --labels "fifo,other" -o pingpong-rt-vs-non-rt.png