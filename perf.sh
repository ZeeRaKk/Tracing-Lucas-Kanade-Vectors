rtlat timer --cpu 7 --policy fifo --prio 80 --duration 10m --out 1-sans-concurrent.json
rtlat timer --cpu 7 --policy fifo --prio 80 --duration 10m --load-cpus 7 --load-kind cpu --out 2-fifo.json
rtlat timer --cpu 7 --policy rr   --prio 80 --duration 10m --load-cpus 7 --load-kind cpu --out 3-rr.json
rtlat timer --cpu 7 --policy other          --duration 10m --load-cpus 7 --load-kind cpu --out 4-other.json
rtlat timer --cpu 7 --policy other          --duration 10m --load-cpus 7 --load-kind memcpy --out 5-other-memcpy.json
rtlat pingpong --cpu 7 --cpu2 8 --policy fifo --prio 80 --duration 10m --load-cpus 7-8 --load-kind cpu --out 6-pp-fifo.json
rtlat pingpong --cpu 7 --cpu2 8 --policy other          --duration 10m --load-cpus 7-8 --load-kind cpu --out 7-pp-other.json


rtlat timer --cpu 5 --policy fifo --prio 80 --duration 10m --out 8-ni-sans-concurrent.json
rtlat timer --cpu 5 --policy fifo --prio 80 --duration 10m --load-cpus 5 --load-kind cpu --out 9-ni-fifo.json
rtlat timer --cpu 5 --policy rr   --prio 80 --duration 10m --load-cpus 5 --load-kind cpu --out 10-ni-rr.json
rtlat timer --cpu 5 --policy other          --duration 10m --load-cpus 5 --load-kind cpu --out 11-ni-other.json
rtlat timer --cpu 5 --policy other          --duration 10m --load-cpus 5 --load-kind memcpy --out 12-ni-other-memcpy.json
rtlat pingpong --cpu 5 --cpu2 4 --policy fifo --prio 80 --duration 10m --load-cpus 4-5 --load-kind cpu --out 13-ni-pp-fifo.json
rtlat pingpong --cpu 5 --cpu2 4 --policy other          --duration 10m --load-cpus 4-5 --load-kind cpu --out 14-ni-pp-other.json

python3 rtlat_plot.py 1-sans-concurrent.json 2-fifo.json 3-rr.json 4-other.json 5-other-memcpy.json \
  --labels "sans concurrent,fifo,rr,other,other memcpy" -o rt-vs-non-rt.png
python3 rtlat_plot.py 6-pp-fifo.json 7-pp-other.json --labels "fifo,other" -o pingpong-rt-vs-non-rt.png


python3 rtlat_plot.py 8-ni-sans-concurrent.json 9-ni-fifo.json 10-ni-rr.json 11-ni-other.json 12-ni-other-memcpy.json \
  --labels "sans concurrent,fifo,rr,other,other memcpy" -o non-isole-rt-vs-non-rt.png
python3 rtlat_plot.py 2-fifo.json 9-ni-fifo.json 4-other.json 11-ni-other.json \
  --labels "fifo isolé,fifo non isolé,other isolé,other non isolé" -o isole-vs-non-isole.png
python3 rtlat_plot.py 6-pp-fifo.json 13-ni-pp-fifo.json 7-pp-other.json 14-ni-pp-other.json \
  --labels "fifo isolé,fifo non isolé,other isolé,other non isolé" -o pingpong-isole-vs-non-isole.png