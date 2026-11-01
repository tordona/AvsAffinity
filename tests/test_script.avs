# AvsAffinity Test Script
# Verifies filter instantiation, debug logging, and prefetch compatibility
ColorBars(640, 360)
last = FunctionExists("PinWorkerThreads") ? last.PinWorkerThreads(debug=true) : last
Prefetch(4, 4)
