gst-launch-1.0 filesrc location=/chemin/vers/video.mp4 ! decodebin ! videoconvert ! videoscale ! videorate ! \
  video/x-raw,width=640,height=480,framerate=30/1 ! \
  vp8enc error-resilient=partitions keyframe-max-dist=15 auto-alt-ref=true cpu-used=5 deadline=1 ! \
  rtpvp8pay ! udpsink host=127.0.0.1 port=5004 sync=true