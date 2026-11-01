"""PDF upload -> print queue for a locally attached HP LaserJet (CUPS).

Anything uploaded as a PDF is printed; on success the file is moved to printed/.
"""

import os
import re
import shutil
import threading
import time
import uuid
from collections import OrderedDict
from queue import Queue

import cups
from flask import Flask, jsonify, render_template_string, request

PRINTER = os.environ.get("PDFPRINT_PRINTER", "HP-LaserJet-Professional-P1108")
BASE_DIR = os.environ.get("PDFPRINT_DIR", os.path.dirname(os.path.abspath(__file__)))
SPOOL_DIR = os.path.join(BASE_DIR, "spool")
PRINTED_DIR = os.path.join(BASE_DIR, "printed")
MAX_BYTES = int(os.environ.get("PDFPRINT_MAX_MB", "50")) * 1024 * 1024
JOB_TIMEOUT = int(os.environ.get("PDFPRINT_TIMEOUT", "240"))
BIND = os.environ.get("PDFPRINT_BIND", "0.0.0.0")
PORT = int(os.environ.get("PDFPRINT_PORT", "8080"))
HISTORY = int(os.environ.get("PDFPRINT_HISTORY", "40"))

POLL_INTERVAL = 2
PDF_MAGIC = b"%PDF-"

STATE_NAMES = {
    cups.IPP_JOB_PENDING: "queued",
    cups.IPP_JOB_PROCESSING: "printing",
    cups.IPP_JOB_HELD: "held",
    cups.IPP_JOB_STOPPED: "paused",
    cups.IPP_JOB_CANCELED: "canceled",
    cups.IPP_JOB_ABORTED: "aborted",
    cups.IPP_JOB_COMPLETED: "printed",
}

app = Flask(__name__)
jobs = OrderedDict()
jobs_lock = threading.Lock()
work = Queue()

UNSAFE = re.compile(r"[^A-Za-z0-9._一-鿿-]+")

PAGE = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PDF 打印</title>
<style>
 body{font:-16px/1.6 system-ui,sans-serif;margin:0;padding:24px;background:#f6f7f9;color:#222}
 .box{max-width:640px;margin:0 auto;background:#fff;border-radius:12px;padding:24px;
      box-shadow:0 1px 4px rgba(0,0,0,.12)}
 h1{font-size:20px;margin:0 0 4px}
 .sub{color:#666;font-size:14px;margin-bottom:20px}
 #drop{border:2px dashed #b9c0ca;border-radius:10px;padding:36px 16px;text-align:center;
       color:#555;cursor:pointer;transition:.15s}
 #drop.over{border-color:#2f80ed;background:#eef5ff;color:#2f80ed}
 input[type=file]{display:none}
 ul{list-style:none;padding:0;margin:20px 0 0}
 li{display:flex;justify-content:space-between;gap:12px;padding:10px 0;
    border-top:1px solid #eee;font-size:14px}
 li span:first-child{word-break:break-all}
 .name{color:#888;font-size:12px;flex:none}
 .tag{padding:1px 8px;border-radius:99px;font-size:12px;flex:none}
 .printed{background:#e6f6ea;color:#1a7f37}
 .printing,.queued,.sending{background:#eaf2ff;color:#1c5ed6}
 .failed{background:#fdeceb;color:#c0392b}
</style>
<div class=box>
 <h1>PDF 上传即打印</h1>
 <div class=sub>目标打印机：{{ printer }} · 只有打印成功的文件才会归档到 printed/</div>
 <label id=drop>点击选择或把 PDF 拖到这里<input type=file id=f accept=application/pdf multiple>
 </label>
 <ul id=list></ul>
</div>
<script>
 var TAG = {queued:'排队中', sending:'提交中', printing:'打印中', printed:'已打印', failed:'失败'};
 var drop = document.getElementById('drop'), list = document.getElementById('list');

 function send(files){
   for (var i = 0; i < files.length; i++) {
     (function(file){
       var fd = new FormData();
       fd.append('file', file);
       render([{name:file.name, status:'sending', message:'正在上传', time:''}]);
       fetch('/upload', {method:'POST', body:fd})
         .then(refresh, refresh);
     }(files[i]));
   }
   setTimeout(refresh, 800);
 }

 function render(items){
   list.innerHTML = '';
   for (var i = items.length - 1; i >= 0; i--) {
     var j = items[i], li = document.createElement('li');
     var n = document.createElement('span'); n.textContent = j.name;
     var m = document.createElement('span'); m.className = 'name'; m.textContent = j.message || '';
     var t = document.createElement('span'); t.className = 'tag ' + j.status;
     t.textContent = TAG[j.status] || j.status;
     li.appendChild(n); li.appendChild(m); li.appendChild(t);
     list.appendChild(li);
   }
 }

 function refresh(){
   fetch('/jobs').then(function(r){ return r.json(); }).then(render).catch(function(){});
 }

 drop.onclick = function(){ document.getElementById('f').click(); };
 document.getElementById('f').onchange = function(e){ send(e.target.files); e.target.value = ''; };
 ['dragenter','dragover'].forEach(function(ev){
   drop.addEventListener(ev, function(e){ e.preventDefault(); drop.classList.add('over'); }); });
 ['dragleave','drop'].forEach(function(ev){
   drop.addEventListener(ev, function(e){ e.preventDefault(); drop.classList.remove('over'); }); });
 drop.addEventListener('drop', function(e){ send(e.dataTransfer.files); });
 refresh();
 setInterval(refresh, 2000);
</script>
"""


def safe_name(raw):
    name = os.path.basename(raw or "").replace("\x00", "")
    name = UNSAFE.sub("_", name).strip("._") or "upload.pdf"
    if not name.lower().endswith(".pdf"):
        name += ".pdf"
    return name[:120]


def unique_dest(directory, name):
    stem, ext = os.path.splitext(name)
    dest = os.path.join(directory, name)
    n = 1
    while os.path.exists(dest):
        dest = os.path.join(directory, "%s-%d%s" % (stem, n, ext))
        n += 1
    return dest


def set_job(job_id, **fields):
    with jobs_lock:
        if job_id in jobs:
            jobs[job_id].update(fields)


def wait_for_job(conn, printer_job_id):
    """Poll CUPS until the job leaves the queue. Returns (ok, detail)."""
    deadline = time.time() + JOB_TIMEOUT
    last = "completed"
    while time.time() < deadline:
        try:
            attrs = conn.getJobAttributes(
                printer_job_id, ["job-state", "job-state-reasons"])
        except Exception:
            return True, last          # purged from history: finished ok
        state = attrs.get("job-state")
        reasons = attrs.get("job-state-reasons", "")
        last = "%s (%s)" % (STATE_NAMES.get(state, "state-%s" % state), reasons)
        if state == cups.IPP_JOB_COMPLETED:
            return True, last
        if state in (cups.IPP_JOB_ABORTED, cups.IPP_JOB_CANCELED):
            return False, last
        time.sleep(POLL_INTERVAL)
    return False, "timeout after %ds, last state: %s" % (JOB_TIMEOUT, last)


def process(job_id):
    with jobs_lock:
        entry = dict(jobs[job_id])
    path, name = entry["path"], entry["name"]

    try:
        conn = cups.Connection()
        printer_job_id = conn.printFile(PRINTER, path, name, {})
    except Exception as exc:
        set_job(job_id, status="failed", message="CUPS 拒绝该作业: %s" % exc)
        return

    set_job(job_id, printer_job_id=printer_job_id, status="printing",
            message="等待打印机输出")

    ok, detail = wait_for_job(conn, printer_job_id)
    if not ok:
        set_job(job_id, status="failed",
                message="打印未完成: %s（文件保留在 spool/）" % detail)
        return

    dest = unique_dest(PRINTED_DIR, name)
    try:
        shutil.move(path, dest)
    except Exception as exc:
        set_job(job_id, status="failed",
                message="已打印，但移入 printed/ 失败: %s" % exc)
        return

    set_job(job_id, status="printed",
            message="%s -> printed/%s" % (detail, os.path.basename(dest)))


def worker():
    while True:
        job_id = work.get()
        try:
            process(job_id)
        except Exception as exc:
            set_job(job_id, status="failed", message="内部错误: %s" % exc)
        finally:
            work.task_done()


@app.route("/")
def index():
    return render_template_string(PAGE, printer=PRINTER)


@app.route("/upload", methods=["POST"])
def upload():
    f = request.files.get("file")
    if f is None or not f.filename:
        return jsonify(status="failed", message="没有收到文件"), 400

    name = safe_name(f.filename)
    job_id = uuid.uuid4().hex[:8]
    dest = os.path.join(SPOOL_DIR, "%s_%s" % (job_id, name))

    if f.stream.read(len(PDF_MAGIC)) != PDF_MAGIC:
        return jsonify(status="failed", message="只接受 PDF 文件"), 415
    f.stream.seek(0)

    size = 0
    with open(dest, "wb") as out:
        while True:
            chunk = f.stream.read(65536)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_BYTES:
                out.close()
                os.remove(dest)
                return jsonify(
                    status="failed",
                    message="文件超过 %d MB" % (MAX_BYTES // (1024 * 1024))), 413
            out.write(chunk)

    if size == 0:
        os.remove(dest)
        return jsonify(status="failed", message="空文件"), 400

    with jobs_lock:
        jobs[job_id] = {
            "id": job_id, "name": name, "path": dest, "size": size,
            "status": "queued", "message": "已加入队列",
            "time": time.strftime("%H:%M:%S"),
        }
        while len(jobs) > HISTORY:
            jobs.popitem(last=False)
    work.put(job_id)
    return jsonify(status="queued", message="已加入打印队列 (%s)" % job_id), 200


@app.route("/jobs")
def jobs_view():
    with jobs_lock:
        out = []
        for entry in jobs.values():
            out.append({k: v for k, v in entry.items() if k != "path"})
    return jsonify(out)


def main():
    for d in (SPOOL_DIR, PRINTED_DIR):
        os.makedirs(d, exist_ok=True)
    threading.Thread(target=worker, daemon=True).start()
    app.run(host=BIND, port=PORT, threaded=True)


if __name__ == "__main__":
    main()
