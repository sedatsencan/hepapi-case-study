import os

from flask import Flask, render_template, redirect
from pymongo import MongoClient, ReturnDocument
from classes import *

# config system
app = Flask(__name__)
app.config.update(dict(SECRET_KEY=os.environ.get('SECRET_KEY', 'yoursecretkey')))
client = MongoClient(os.environ.get('MONGODB_URI', 'localhost:27017'))
db = client.TaskManager

# Runs on every replica at startup. The unique index plus the upsert make this
# safe when several replicas start at once: the server settles the race, so the
# counter document exists exactly once instead of once per replica.
db.settings.create_index('name', unique=True)
db.settings.update_one({'name': 'task_id'}, {'$setOnInsert': {'value': 0}}, upsert=True)

def nextTaskID():
    # Reads the counter and advances it in a single server-side operation, so
    # two concurrent requests can never be handed the same id.
    return db.settings.find_one_and_update(
        {'name': 'task_id'},
        {'$inc': {'value': 1}},
        return_document=ReturnDocument.BEFORE)['value']

def createTask(form):
    title = form.title.data
    priority = form.priority.data
    shortdesc = form.shortdesc.data
    task_id = nextTaskID()

    task = {'id':task_id, 'title':title, 'shortdesc':shortdesc, 'priority':priority}

    db.tasks.insert_one(task)
    return redirect('/')

def deleteTask(form):
    key = form.key.data
    title = form.title.data

    if(key):
        print(key, type(key))
        db.tasks.delete_many({'id':int(key)})
    else:
        db.tasks.delete_many({'title':title})

    return redirect('/')

def updateTask(form):
    key = form.key.data
    shortdesc = form.shortdesc.data
    
    db.tasks.update_one(
        {"id": int(key)},
        {"$set":
            {"shortdesc": shortdesc}
        }
    )

    return redirect('/')

def resetTask(form):
    db.tasks.drop()
    # Resets the counter in place rather than dropping the collection, which
    # would take the unique index with it.
    db.settings.update_one({'name':'task_id'}, {'$set': {'value':0}}, upsert=True)
    return redirect('/')

@app.route('/', methods=['GET','POST'])
def main():
    # create form
    cform = CreateTask(prefix='cform')
    dform = DeleteTask(prefix='dform')
    uform = UpdateTask(prefix='uform')
    reset = ResetTask(prefix='reset')

    # response
    if cform.validate_on_submit() and cform.create.data:
        return createTask(cform)
    if dform.validate_on_submit() and dform.delete.data:
        return deleteTask(dform)
    if uform.validate_on_submit() and uform.update.data:
        return updateTask(uform)
    if reset.validate_on_submit() and reset.reset.data:
        return resetTask(reset)

    # read all data
    docs = db.tasks.find()
    data = []
    for i in docs:
        data.append(i)

    return render_template('home.html', cform = cform, dform = dform, uform = uform, \
            data = data, reset = reset)

if __name__=='__main__':
    app.run(host='0.0.0.0', debug=os.environ.get('FLASK_DEBUG', 'true').lower() == 'true')
