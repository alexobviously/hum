# Yet-to-be-named DSP/generative audio library

Signal processing library built primarily for creative applications. Why?
- I need it to make bangers
- To stop my brain slowly decaying
- I wanted to see what 'low level' code in dart is like

## Design principles
- Built of primitives but allowing for abstraction and composition
- Layer based architecture
- Split between compositional node graph builder designed for high level DX, and a low level audio engine for performance
- Support for both realtime and offline audio processing
- Focus is on generative music and sound design, but supports any signal processing use case

## Architecture

### Basics
The basic building block is an `AudioNode`, which defines the high level API for a node in the graph. They have inlets and outlets to define how they are able to connect to other nodes. An `AudioNode` builds and updates an `AudioProcessor`, which is the low level signal processing unit responsible for reading and writing buffers.  

Node graphs are compiled to a flat list of processors using a topological sort. The processors have no knowledge of each other, only how many buffers they have available to them, and how many they write out to.  

In realtime mode, the pipeline of processors lives on an isolate which does not share memory with the main isolate. This allows it to avoid GC-related stutter, because processors do not allocate to the heap. They just do operations on the buffers they have access to and use stack memory exclusively (be careful with your processor code!).  

Control-rate parameters (in contrast to signal-rate paramneters) are part of a push-based event loop, which is run on the main isolate. Things like MIDI inputs or clock-based events (sequencers etc) work by pushing changes into a specific node, which perpetuates changes to other nodes that might need it.  

### Node graph composition
I'll elaborate on this later but basically nodes have inlets and outlets, and outlets can be used as inputs to other nodes through `ControlParam.signal` type parameters.