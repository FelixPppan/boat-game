# Hand tracking (Python)
 
Reads the webcam, finds hand landmarks with MediaPipe, and streams them to
Godot over UDP so `HandTracking` (the Godot autoload) can use them.
 
## Requirements
 
- Python 3.11 or 3.12 (MediaPipe may not have a build for newer versions yet)
- A webcam
## First-time setup
 
Run these from the project's `python` folder:
 
```
cd .\python\
python -m venv .venv
```
 
Activate the virtual environment. You need to do this every time you open a
new terminal to work on this project.
 
```
.venv\Scripts\activate          # Windows
source .venv/bin/activate       # macOS/Linux
```
 
You should see `(.venv)` at the start of your prompt once it's active.
 
Install the libraries:
 
```
pip install -r requirements.txt
```
 
## Running it
 
With the venv activated, from the `python` folder:
 
```
python hand_tracking.py
```
 
It may take a
moment before the camera window appears. After that, an OpenCV window shows
your webcam feed with the tracked hand landmarks drawn on it. **Press `q` in that window to quit.**