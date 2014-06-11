#!/usr/bin/python
# -*- coding: utf-8 -*-

from xml.etree.ElementTree import Element, SubElement, Comment, tostring
from xml.etree import ElementTree
from xml.dom import minidom

import urllib2
import json
import datetime
import os
import subprocess

# Main Constants
config_file = "config.json"
recording_dir = 'recording'
queue_dir = 'queue'
completed_dir = 'completed'

schedule_ids = {}

json_format="%Y-%m-%d %H:%M:%S"
dv_format="%Y-%m-%d_%H-%M-%S"

def prettify(elem):
    """Return a pretty-printed XML string for the Element.
    """
    rough_string = ElementTree.tostring(elem, 'utf-8')
    reparsed = minidom.parseString(rough_string)
    return reparsed.toprettyxml(indent="  ")

def open_json(filename):
    if "://" in filename:
        json_data = urllib2.urlopen(filename)
    else:
        json_data = open(filename)
    data = json.load(json_data)
    json_data.close()
    return data

def dv_to_datetime(filename):
    """ Return a datetime object if filename is <timestamp>.dv, else None """
    if filename[-3:] == ".dv":
        try:
            time = datetime.datetime.strptime(filename[:-3], dv_format)
        except ValueError:
            time = None
    else:
        time = None
    return time

def potential_files(dv_list, start, end, buffer):
    """ Return a list of times that are roughly within start & end times """
    files = []
    for time in dv_list:
        if start-buffer <= time <= end+buffer:
            dv_file = {
                'filename' : time.strftime(dv_format) + ".dv",
                'filepath' : "/".join([recording_root, room, date])
            }
            files.append(dv_file)
    return sorted(files)


# read the config file
config_data = open_json(config_file)
base_dir = config_data["base_dir"]
schedule_file = base_dir + "/" + config_data["schedule"]
 
# first pass through the recording directory: find the times of all .dv files
recording_root = base_dir + "/" + recording_dir
dvs = {}
for room in os.listdir(recording_root):
    dates = {}
    room_path = recording_root + "/" + room
    for date in os.listdir(room_path):
        date_path = room_path + "/" + date
    dates[date] = [dv_to_datetime(f) for f in os.listdir(date_path)]
    dvs[room] = dates

    # read the schedule file, removing spaces in room names
    raw = open_json(schedule_file)
    schedule_data = {k.replace(" ", ""):v for k,v in raw.items()}
    # match items in the schedule with .dv files by timestamp
    buffer = datetime.timedelta(minutes=10)
    fields = ["presenters", "title", "start", "end"]
    talks = {}
    for room in schedule_data:
        for talk in schedule_data[room]:
            id = talk["schedule_id"]
            talks[id] = {k:talk[k] for k in fields}
            start = datetime.datetime.strptime(talk["start"], json_format)
            end = datetime.datetime.strptime(talk["end"], json_format)
            date = start.strftime("%Y-%m-%d")
            try: 
                playlist = potential_files(dvs[room][date], start, end, buffer)
            except KeyError:
                playlist = []
            talks[id]["playlist"] = playlist

"""
User interface stuff
"""



def prompt(string, default=None):
    """ Return user input, or default value if they just press enter """
    if default is not None:
        return raw_input("{0} [{1}]: ".format(string, default)) or default
    else:
        return raw_input("{0}: ".format(string))

def prompt_for_number(string, default=None):
    """ Return user input as an int if possible, else None """
    response = prompt(string, default)
    try:
        return int(response)
    except ValueError:
        return None

def get_duration(filename):
# from matt, untested since i don't have test files
# not quite sure what this returns/outputs
    cmd = "exiftool -duration " + filename
    p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for line in p.stdout:
        print line.split()[2]
        return

#          'filename' : time.strftime(dv_format) + ".dv",
#          'filepath' : "/".join([recording_root, room, date])
DEVNULL = open(os.devnull, 'wb')

print "Available jobs:", [t for t,v in talks.items() if v["playlist"]]
n = prompt_for_number("Select a job")

while n: 
    talk = talks[n]

    dvfiles = [z["filepath"] + "/" + z["filename"] for z in talk["playlist"]]
    try:
        subprocess.Popen(["vlc"] + dvfiles, stderr=DEVNULL)
    except KeyError:
        n = prompt_for_number("Select a job")
        continue

    print
    print "Title:", talk["title"]
    print "Presenter:", talk["presenters"]
    print "Files:"
    dvfiles = [z["filepath"] + "/" + z["filename"] for z in talk["playlist"]]
    for i, dvfile in enumerate(dvfiles):
        print i, dvfile

    print
    # our users always type sensible things...right
    start_file = prompt_for_number("Start file", 0)
    start_offset = prompt_for_number("Start time offset seconds", 0)
    end_file = prompt_for_number("End file", len(talk["playlist"])-1)
    end_offset = prompt_for_number("End time offset seconds", 0)
    # should probably be the end of the selected end_file using exiftool

    print
    print "Starting job"
    # this basically prints the cut list which will be used later
    talks[n]["cut_list"] = talk["playlist"][start_file:end_file+1]
    talks[n]["cut_list"][0]["in"] = start_offset
    talks[n]["cut_list"][-1]["out"] = end_offset

    # Now onto the xml stuff. Very rough and ready but will clean up when it works. Need sleep will fix it up tomorrow/today ;-)
    #tmpmlt = open(talk["schedule_id"], 'rw')
    print talks[n]["cut_list"]
    mlt = Element('mlt')
    resources = []
    producers = []
    print
    print "----------"
    print "Available jobs:", [t for t,v in talks.items() if v["playlist"]]
    n = prompt_for_number("Select a job")

#    for i,resources in enumerate(talk["cut_list"]):
#        print i, resources

'''
        producer[i] = SubElement(mlt, 'producer', id=resource["filename"])
        
    intro = SubElement(mlt, 'producer', id='intro')
    intro_property = SubElement(intro, "property", name="resource")
    intro_property.text = "intro.dv"
    title = SubElement(mlt, "producer", id="title")
    title_property = SubElement(title, 'property', name="resource")
    title_property = "title.png"
    play_intro = SubElement(mlt, "playlist", id="playlist0")
    producer0 = SubElement(play_intro, "entry producer=\"intro\" in=\"0\" out=\"75\""   )
    producer1 = SubElement(play_intro, "entry producer=\"title\" in=\"75\" out=\"1000000\"")

    print prettify(mlt)

    tmpmlt.write(prettify(mlt));
    intro.close()
'''
'''

<?xml version="1.0" ?>
<mlt>
  <producer id="intro">
    <property name="resource">intro.dv</property>
  </producer>
  <producer id="title">
    <property name="resource"/>
  </producer>
  <playlist id="playlist0">
    <entry in="0" out="75" producer="intro"/>
    <entry in="75" out="1000000" producer="title"/>
  </playlist>
</mlt>

for i,dvfile in enumerate(dvfiles):
if start_file <= i <= end_file:
       extra = ""
       if i == start_file:
          extra = "(start: {0} seconds)".format(start_offset)
       if i == end_file:
          extra = "(end: {0} seconds)".format(end_offset)
       print dvfile, extra
       #talks[n]["files"][i]["in"] = start_offset
       #talks[n]["files"][i]["out"] = end_offset
       print talks[n]["files"][i]
    else:
        print talks[n]["files"].remove(i)
    print talks[n]["files"]
   <mlt>
 for file in cut_list:
        <producer id="filename">
          <property name="resource">filepath/filename</property>
        </producer>
        <playlist id="playlist0">
 for file in cut_list:
            <entry producer="filename" if file[in]: in="file[in]" if file[out] out="file[out]"/>
        </playlist>
        </mlt>
        
        # print mltfile
    # do lots of melt calculations or something here
    # then subprocess.Popen stuff

    print
    print "----------"
    print "Available jobs:", [t for t,v in talks.items() if v["files"]]
    n = prompt_for_number("Select a job")
'''
