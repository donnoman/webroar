/* WebROaR - Ruby Application Server - http://webroar.in/
 * Copyright (C) 2009  Goonj LLC
 *
 * This file is part of WebROaR.
 *
 * WebROaR is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * WebROaR is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with WebROaR.  If not, see <http://www.gnu.org/licenses/>.
 */
#include <wr_request.h>
#include <wr_access_log.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/un.h>

/** Private functions */
static void wr_req_hearer_write_cb(struct ev_loop*, struct ev_io*, int);

static inline void wr_wait_watcher_start(wr_wkr_t *w) {
  w->trials_done = 0;
  // Clear WR_WKR_PING_SENT, WR_WKR_PING_REPLIED and WR_WKR_HANG state.
  w->state &= (~224);
  w->t_wait.repeat = WR_WKR_IDLE_TIME;
  ev_timer_again(w->loop, &w->t_wait);
}

/** Check for pending request to process */
static inline void wr_wrk_allocate(wr_wkr_t* worker) {
  LOG_FUNCTION
  wr_req_t* req;
  wr_app_t* app = worker->app;
  wr_svr_t* server = app->svr;
  int retval;
  //do we need high load ratio check here?
  if(app && app->msg_que->q_count > 0) {
    //There is pending request
    WR_QUEUE_FETCH(app->msg_que, req)  ;

    if(req == NULL) {
      WR_QUEUE_INSERT(app->free_wkr_que, worker, retval)  ;
    } else {
      LOG_DEBUG(4,"Allocate worker %d to req id %d", worker->id , req->id);
      req->wkr = worker;
      worker->req = req;
      worker->watcher.data = req;
      ev_io_init(&worker->watcher, wr_req_hearer_write_cb, worker->fd, EV_WRITE);
      ev_io_start(server->ebb_svr.loop,&worker->watcher);
    }
  } else if(app) {
    //No any pending request. Add Worker to free worker list
    LOG_DEBUG(4,"Message queue is empty");
    WR_QUEUE_INSERT(app->free_wkr_que, worker, retval)  ;
  } else {
    //Remove worker
    LOG_ERROR(SEVERE,"wr_wrk_allocate: Remove worker with pid %d.", worker->pid);
    wr_wkr_free(worker);
  }
}

static inline void wr_wkr_release(wr_req_t* req) {
  LOG_FUNCTION
  wr_wkr_t* worker = req->wkr;

  LOG_DEBUG(DEBUG,"req %d", req->id);
  wr_req_free(req);
  worker->req = NULL;
  //Check applicatio load
  if(worker->app)
    wr_app_chk_load_to_remove_wkr(worker->app);

  // Check worker status before allication
  if(worker->state & WR_WKR_ACTIVE) {
    wr_wrk_allocate(worker);
  } else {
    // Remove worker if it is not active
    LOG_ERROR(SEVERE,"wr_wkr_release: Remove worker with pid %d", worker->pid);
    wr_wkr_remove(worker, 0);
  }
}

/** Reads streamed response from Worker */
static void wr_resp_read_cb(struct ev_loop *loop,struct ev_io *w, int revents) {
  LOG_FUNCTION
  wr_req_t *req = (wr_req_t*) w->data;
  wr_wkr_t *worker = req->wkr;
  ssize_t read;

  LOG_DEBUG(DEBUG,"req %d",req->id);
  //TODO: what to do if there is some unread data for req, and it's get closed?
  if(!(revents & EV_READ))
    return;

  //TODO: can this thing can be improved by directly reading into response_buffer?
  // if we do so we have overhead of allocating and freeing response_buffer.

  read = recv(w->fd,
              req->resp_buf,
              wr_min(WR_RESP_BUF_SIZE,req->resp_buf_len - req->bytes_received),
              0);
  if(read <= 0) {
    ev_io_stop(loop,w);
    LOG_ERROR(WARN,"Error reading response:%s",strerror(errno));
    worker->state += (WR_WKR_ERROR + WR_WKR_HANG);
    wr_ctl_free(worker->ctl);
    return;
  }

  req->bytes_received += read;
  LOG_DEBUG(DEBUG,"Request %d, read %d/%d", req->id, req->bytes_received, req->resp_buf_len);

  //worker responding
  LOG_DEBUG(DEBUG,"Idle watcher reset for worker %d", worker->id);

  if(!req->conn_err) {
    wr_conn_resp_body_add(req->conn, req->resp_buf, read);
  }
  // Check response lenth
  //if(req->bytes_received == req->resp_buf_len) {
  if(req->bytes_received >= req->resp_buf_len) {
    ev_io_stop(loop, w);
    LOG_DEBUG(DEBUG,"Idle watcher stopped for worker %d", worker->id);
    // worker is done with current Request
    worker->req = NULL;
    req->using_wkr = FALSE;

    worker->state &= (~224);
    ev_timer_stop(worker->loop,&worker->t_wait);
    // Close Request once response read
    wr_wkr_release(req);
  } else {
    wr_wait_watcher_start(worker);
  }
}

/** Reads the response from worker, deserialize it, render it to the Request. */
static void wr_resp_len_read_cb(struct ev_loop *loop, struct ev_io *w, int revents) {
  LOG_FUNCTION
  wr_req_t* req = (wr_req_t*) w->data;
  wr_wkr_t *worker = req->wkr;
  ssize_t read;

  LOG_DEBUG(DEBUG,"Request %d",req->id);

  if(!(revents & EV_READ))
    return;

  read = recv(w->fd,
              req->resp_buf + req->bytes_received,
              WR_RESP_BUF_SIZE - req->bytes_received,
              0);

  if(read <= 0) {
    ev_io_stop(loop,w);
    LOG_ERROR(WARN,"Error reading response:%s",strerror(errno));
    worker->state += (WR_WKR_ERROR + WR_WKR_HANG);
    wr_ctl_free(worker->ctl);
    return;
  }

  req->bytes_received =+ read;
  //worker responding
  LOG_DEBUG(DEBUG,"Idle watcher reset for worker %d", worker->id);
  LOG_DEBUG(DEBUG,"bytes read = %d", req->bytes_received);

  scgi_t* scgi = scgi_parse(req->resp_buf, req->bytes_received);

  if(scgi) {
    ev_io_stop(loop,w);
    const char *value = scgi_header_value_get(scgi, SCGI_CONTENT_LENGTH);
    // Set response length
    if(value)
      req->resp_buf_len = atoi(value);
    else
      req->resp_buf_len = 0;
    
    // Set rsponse code
    value = scgi_header_value_get(scgi, RESP_CODE);
    if(value)
      req->resp_code = atoi(value);
    else
      req->resp_code = 0;
    
    // Set content length
    value = scgi_header_value_get(scgi, RESP_CONTENT_LENGTH);
    if(value)
      req->resp_body_len = atoi(value);
    else
      req->resp_body_len = 0;
    
    LOG_DEBUG(DEBUG,"resp_code = %d, content len = %d, resp len = %d",
              req->resp_code,
              req->resp_body_len,
              req->resp_buf_len);
    // Response length should be greater than 0
    if(req->resp_buf_len == 0) {
      //TODO: Render 500 Internal Error, close Request, allocate worker to next Request
      LOG_ERROR(WARN,"Got response len 0");
      ev_io_stop(loop,w);
      worker->state += (WR_WKR_ERROR + WR_WKR_HANG);
      wr_ctl_free(worker->ctl);
      return;
    }

    if(!req->conn_err && req->app && req->app->svr->conf->server->flag & WR_SVR_ACCESS_LOG) {
      wr_access_log(req);
    }

    scgi_free(req->scgi);
    req->scgi = NULL;

    req->bytes_received = scgi->body_length;
    LOG_DEBUG(DEBUG,"wr_resp_len_read_cb() bytes read = %d", req->bytes_received);
    if(req->bytes_received > 0 && !req->conn_err) {
      wr_conn_resp_body_add(req->conn, scgi->body, scgi->body_length);
    }

    scgi_free(scgi);

    // Check for response length
    if(req->resp_buf_len == req->bytes_received) {
      LOG_DEBUG(DEBUG,"Idle watcher stopped for worker %d", worker->id);
      // worker is done with current Request
      worker->req = NULL;
      req->using_wkr = FALSE;
      worker->state &= (~224);
      ev_timer_stop(worker->loop,&worker->t_wait);
      // Close Request once complete response read
      wr_wkr_release(req);
    } else {
      LOG_DEBUG(DEBUG,"wr_resp_len_read_cb() Request %d, read %d/%d",
                req->id,
                req->bytes_received,
                req->resp_buf_len);
      ev_io_init(w,wr_resp_read_cb, w->fd,EV_READ);
      ev_io_start(loop,w);
      wr_wait_watcher_start(worker);
    }
  }
}

/** Send SCGI formatted request stream to Worker*/
static void wr_req_body_write_cb(struct ev_loop *loop, struct ev_io *w, int revents) {
  LOG_FUNCTION
  wr_req_t *req = (wr_req_t*) w->data;
  wr_wkr_t *worker = req->wkr;
  ssize_t sent = 0;
  LOG_DEBUG(DEBUG, "Request %d",req->id);
  if(!(revents & EV_WRITE))
    return;

  if(req->upload_file) {
    char buffer[WR_REQ_BODY_MAX_SIZE];
    ssize_t read;
    int rv=fseek(req->upload_file,req->bytes_sent,SEEK_SET);
    if(rv<0) {
      LOG_ERROR(WARN,"Error reading file:%s",strerror(errno));
      return;
    }
    read = fread(buffer,1,WR_REQ_BODY_MAX_SIZE,req->upload_file);
    sent = send(w->fd, buffer, read, 0);
  }

  if(sent <= 0) {
    ev_io_stop(loop,w);
    LOG_ERROR(WARN,"Error sending request:%s",strerror(errno));
    worker->state += (WR_WKR_ERROR + WR_WKR_HANG);
    wr_ctl_free(worker->ctl);
    return;
  }

  req->bytes_sent += sent;
  LOG_DEBUG(DEBUG,"Request %d sent %d/%d",  req->id, req->bytes_sent, req->ebb_req->content_length);

  if(req->ebb_req->content_length == req->bytes_sent) {
    ev_io_stop(loop,w);

    LOG_DEBUG(DEBUG,"Sent request body for Request %d to worker %d", req->id, worker->id);
    if(req->upload_file) {
      fclose(req->upload_file);
      remove(req->upload_file_name->str);
      wr_buffer_free(req->upload_file_name);
      req->upload_file = NULL;
    }

    scgi_free(req->scgi);
    req->scgi = NULL;

    ev_io_init(w,wr_resp_len_read_cb,w->fd,EV_READ);
    ev_io_start(loop,w);
    //We are waiting for response from worker, start idle watcher for it
    LOG_DEBUG(DEBUG,"Idle watcher started for worker %d", worker->id);
    wr_wait_watcher_start(worker);
    //wr_wkr_idle_watch_reset(worker);
  }
}

/** Start writing SCGI formatted request to Worker */
//whenever there is a pending request for processing and worker's fd is ready for write, it will dump serialized data to worker by this function
static void wr_req_hearer_write_cb(struct ev_loop *loop, struct ev_io *w, int revents) {
  LOG_FUNCTION
  int error_flag=0;
  wr_req_t* req = (wr_req_t*) w->data;
  wr_wkr_t *worker = req->wkr;
  LOG_DEBUG(DEBUG,"Request %d",req->id);
  if (!(revents & EV_WRITE))
    return;

  //TODO: we can improve here by sending request body part also
  if(scgi_send(req->scgi, w->fd) <= 0){
    ev_io_stop(loop,w);
    LOG_ERROR(WARN,"Error sending request:%s",strerror(errno));
    worker->state += (WR_WKR_ERROR + WR_WKR_HANG);
    wr_ctl_free(worker->ctl);
    return;
  }
  LOG_DEBUG(DEBUG,"Request %d write %d/%d", req->id,  req->scgi->bytes_sent, 
          req->scgi->length);
  if(req->scgi->bytes_sent == req->scgi->length) {
    ev_io_stop(loop,w);
    LOG_DEBUG(DEBUG,"Sent request header for Request %d to worker %d", req->id, worker->id);
    req->bytes_sent = 0;

    if(req->upload_file) {
      ev_io_init(w,wr_req_body_write_cb,w->fd,EV_WRITE);
    } else {
      ev_io_init(w, wr_resp_len_read_cb, w->fd,EV_READ);
      //We are waiting for response from worker, start idle watcher for it
      LOG_DEBUG(DEBUG,"Idle watcher started for worker %d", worker->id);
      //wr_wkr_idle_watch_reset(worker);
      wr_wait_watcher_start(worker);
    }
    ev_io_start(loop,w);
  }
}

/*******************************************
 *       Worker Function Definition          *
 *******************************************/

static inline void wr_wkr_recreate(wr_wkr_t *worker) {
  LOG_FUNCTION
  wr_req_t *req = worker->req;

  // Need to stop ev_io so that all the pending call related to worker turns out to void
  ev_io_stop(worker->loop, &worker->watcher);
  worker->state &= (~224);
  worker->state |= WR_WKR_HANG;
  ev_timer_stop(worker->loop,&worker->t_wait);

  if(req) {
    LOG_ERROR(SEVERE,"Worker %d Hangup. Killing it. Request id = %d, Connection id = %d, Request Path is %s",
              worker->id, req->id, req->conn->id, req->req_uri.str);
    wr_conn_err_resp(req->conn, WR_HTTP_STATUS_500);
  }
  wr_app_t *app = worker->app;
  worker->state |= WR_WKR_ERROR;
  wr_wkr_remove(worker, 0);
  //create new worker if required
  if(TOTAL_WORKER_COUNT(app) < app->conf->min_worker ||
      app->msg_que->q_count > app->high_ratio) {
    wr_app_wkr_add(app);
  }
}

/** This would get called when idel time watcher goes timeout */
static void wr_wkr_wait_cb(struct ev_loop *loop, ev_timer *w, int revents) {
  LOG_FUNCTION
  wr_wkr_t *worker = (wr_wkr_t*)w->data;

  //ev_timer_stop(loop, &worker->t_idle);
  ev_timer_stop(loop, &worker->t_wait);

  if(worker->app == NULL) {
    LOG_INFO("wr_wkr_wait_cb: Worker removed with pid %d", worker->pid);
    wr_wkr_free(worker);
  } else if(worker->trials_done < WR_PING_TRIALS) {
    worker->trials_done++;
    LOG_INFO("Worker %d with pid %u ping for trial no %d",
             worker->id, worker->pid, worker->trials_done);
    worker->t_wait.repeat = WR_PING_WAIT_TIME;
    worker->state |= (WR_WKR_HANG | WR_WKR_PING_SENT);
    if(worker->state & WR_WKR_PING_REPLIED) {
      worker->state ^= WR_WKR_PING_REPLIED;
    }
    scgi_t *scgi = scgi_new();
    scgi_header_add(scgi, "COMPONENT", strlen("COMPONENT"), "WORKER", strlen("WORKER"));
    scgi_header_add(scgi, "METHOD", strlen("METHOD"), "PING", strlen("PING"));
    if(scgi_build(scgi)!=0) {
      LOG_ERROR(WARN,"SCGI request build failed.");
    }
    worker->ctl->scgi = scgi;
    ev_io_start(loop, &worker->ctl->w_write);
    //ev_timer_again(loop, &worker->t_ping_wait);
    ev_timer_again(loop, &worker->t_wait);
  } else {
    //render 500 response to Request, kill the worker
    wr_wkr_recreate(worker);
  }
}

/** Create new worker */
wr_wkr_t* wr_wkr_new(wr_ctl_t *ctl) {
  LOG_FUNCTION
  wr_wkr_t* worker = wr_malloc(wr_wkr_t);
  if(worker == NULL)
    return NULL;

  // Set default value
  worker->ctl = ctl;
  worker->req = NULL;
  worker->fd = 0;
  worker->id = 0;
  worker->pid = 0;
  worker->app = NULL;
  worker->watcher.active = 0;
  worker->state = WR_WKR_CLEAR;
  worker->trials_done = 0;
  worker->t_wait.data = worker;
  worker->loop = ctl->svr->ebb_svr.loop;
  ev_timer_init(&worker->t_wait, wr_wkr_wait_cb, 0., WR_WKR_IDLE_TIME);
  return worker;
}

/** Destroy worker */
void wr_wkr_free(wr_wkr_t *worker) {
  LOG_FUNCTION
  if(worker->state & WR_WKR_ACTIVE) {
    worker->state -= WR_WKR_ACTIVE ;
  }

  if(ev_is_active(&worker->t_wait))
    ev_timer_stop(worker->loop,&worker->t_wait);

  //Kill the process
  if(!(worker->state & WR_WKR_ERROR) &&
      !(worker->state & WR_WKR_DISCONNECT) &&
      worker->req == NULL &&
      worker->pid > 0) {
    LOG_DEBUG(DEBUG,"Stopping worker %d with pid %d...",worker->id, worker->pid);
    LOG_INFO("Stopping worker %d with pid %d...",worker->id, worker->pid);
    scgi_t* remove_req = scgi_new();
    if(remove_req) {
      scgi_header_add(remove_req, "METHOD", strlen("METHOD"), "REMOVE", strlen("REMOVE"));
      scgi_build(remove_req);
      //TODO: made it asynchronous
      send(worker->ctl->fd, remove_req->header + remove_req->start_offset, remove_req->length, 0);
      scgi_free(remove_req);
    } else {
      kill(worker->pid,SIGHUP);
    }
    worker->pid = 0;
  } else if(worker->state & WR_WKR_HANG) {
    kill(worker->pid,SIGKILL);
    LOG_DEBUG(DEBUG,"Worker %d with pid %d killed...",worker->id, worker->pid);
    LOG_INFO("Worker %d with pid %d killed...",worker->id, worker->pid);
  } else if(worker->req && worker->app) {
    LOG_DEBUG(DEBUG,"Worker %d with pid %d. Waiting for worker...",worker->id, worker->pid);
    LOG_INFO("Worker %d with pid %d. Waiting for worker...",worker->id, worker->pid);
    worker->app = NULL;
    worker->t_wait.repeat = WR_WKR_KILL_TIMEOUT;
    ev_timer_again(worker->loop, &worker->t_wait);
    return;
  } else if(worker->req) {
    LOG_DEBUG(DEBUG,"Worker %d with pid %d. Worker cannot served the request.",worker->id, worker->pid);
    LOG_INFO("Worker %d with pid %d. Worker cannot served the request.",worker->id, worker->pid);
    if(ev_is_active(&worker->watcher))
      ev_io_stop(worker->loop,&worker->watcher);
    worker->req->using_wkr = FALSE;
    wr_conn_err_resp(worker->req->conn, WR_HTTP_STATUS_500);
    kill(worker->pid,SIGKILL);
    LOG_DEBUG(DEBUG,"Worker %d with pid %d killed...",worker->id, worker->pid);
  } else {
    kill(worker->pid,SIGKILL);
    LOG_DEBUG(DEBUG,"Worker %d with pid %d killed...",worker->id, worker->pid);
    LOG_INFO("Worker %d with pid %d killed...",worker->id, worker->pid);
  }

  if(worker->ctl) {
    worker->ctl->wkr = NULL;
    wr_ctl_free(worker->ctl);
  }
  //Close socket
  if(worker->fd > 0)
    close(worker->fd);

  free(worker);
}

/** Remove worker */
int wr_wkr_remove(wr_wkr_t *worker, int flag) {
  LOG_FUNCTION
  wr_app_t* app = worker->app;
  int i, index;

  if(worker->state & WR_WKR_ACTIVE)
    worker->state -= WR_WKR_ACTIVE;

  if(app) {
    LOG_INFO("Removing worker %d with pid %d...app->wkr_que->q_count=%d, q_front=%d, q_rear=%d app=%s",
             worker->id, worker->pid,app->wkr_que->q_count,app->wkr_que->q_front,app->wkr_que->q_rear,
             app->conf->name.str);
  } else {
    LOG_INFO("Removing worker %d with pid %d", worker->id, worker->pid);
  }

  if(app && wr_queue_remove(app->wkr_que, worker) == 0) {
    app->high_ratio = TOTAL_WORKER_COUNT(app) * WR_MAX_REQ_RATIO;
    app->low_ratio = WR_QUEUE_SIZE(app->wkr_que) * WR_MIN_REQ_RATIO;

    if(flag) {
      wr_queue_remove(app->free_wkr_que, worker);
    }
    wr_wkr_free(worker);
    return 0;
  } else if(app == NULL) {
    wr_wkr_free(worker);
    return 0;
  }

  return -1;
}

/** Create the Worker */
int wr_wkr_create(wr_svr_t *server, wr_app_conf_t *app_conf) {
  LOG_FUNCTION
  pid_t   pid;
  char   cuid_s[WR_SHORT_STR_LEN],
  cgid_s[WR_SHORT_STR_LEN],
  controller_path[WR_LONG_STR_LEN],
  analytics [WR_SHORT_STR_LEN],
  log_level[WR_SHORT_STR_LEN];

  wr_str_t baseuri;
  wr_string_null(baseuri);

  if(app_conf->baseuri.str) {
    wr_string_dump(baseuri, app_conf->baseuri);
  } else {
    wr_string_new(baseuri, "/", 1);
  }

  sprintf(cuid_s, "%d", app_conf->cuid);
  sprintf(cgid_s, "%d", app_conf->cgid);
  sprintf(log_level, "%d", app_conf->log_level);

  if(server->conf->uds) {
    strcpy(controller_path, server->ctl->sock_path.str);
  } else {
    sprintf(controller_path, "%d", server->ctl->port);
  }
  pid = fork();
  LOG_DEBUG(DEBUG,"Forked PID is  %i, uid = %s, gid =%s, app = %s",pid, cuid_s, cgid_s, app_conf->name.str) ;
  if (pid == 0) {
      LOG_DEBUG(3,"Child is continuing %i",pid);
      setsid();
      int i = 0;
      for (i=getdtablesize();i>=0;--i) {
        //LOG_DEBUG(DEBUG,"closing fd=%d",i);
        close(i); //why??
      }

      /* Close out the standard file descriptors*/

      close(STDIN_FILENO);
      close(STDOUT_FILENO);
      close(STDERR_FILENO);
      i=open("/dev/null",O_RDWR); // open stdin and connect to /dev/null
      int j = dup(i); // stdout
      j = dup(i); // stderr

      LOG_DEBUG(DEBUG,"Before execl():Rails application=%s, uid=%s, gid = %s",app_conf->path.str, cuid_s, cgid_s);
      LOG_DEBUG(DEBUG,"exe file = %s",server->conf->wkr_exe_path.str);
      int rv;
      rv=execl(server->conf->wkr_exe_path.str, server->conf->wkr_exe_path.str,
               "-a", app_conf->path.str,
               "-e", app_conf->env.str,
               "-u", cuid_s,
               "-g", cgid_s,
               "-c", controller_path,
               "-i", (server->conf->uds? "y" : "n"),
               "-t", app_conf->type.str,
               "-n", app_conf->name.str,
               "-p", (app_conf->analytics? "y" : "n"),
               "-r", baseuri.str,
               "-b", server->conf->ruby_lib_path.str,
               "-o", server->conf->wr_root_path.str,
               "-k", (WR_SVR_KEEP_ALIVE? "y" : "n"),
               "-l", log_level,
               NULL);
      wr_string_free(baseuri);
      if(rv<0) {
        LOG_ERROR(5,"Unable to run %s: %s\n", server->conf->wkr_exe_path.str, strerror(errno));
        fprintf(stderr, "Unable to run %s: %s\n", server->conf->wkr_exe_path.str, strerror(errno));
        fflush(stderr);
        _exit(1);
      }
  } else if (pid == -1) {
    wr_string_free(baseuri);
    LOG_ERROR(5,"Cannot fork a new process %i", errno);
  } else {
    wr_string_free(baseuri);
    //Temporary Hack
    return pid;
  }
  return -1;
}

/** Request callback called by ebb Request*/
/* It will be called after request is parsed and environment hash is ready.
 * Request is inserted into application queue, and one of free worker allocated to a Request. */
/** Dispatch the request to Worker process */
void wr_wkr_dispatch_req(wr_req_t* req) {
  LOG_FUNCTION
  wr_req_t* new_req = NULL;
  wr_wkr_t* worker = NULL;

  // Check load balance
  wr_app_chk_load_to_add_wkr(req->app);

  //Dispatch message
  WR_APP_MSG_DISPATCH(req->app, new_req, worker)    ;

  if(new_req && worker) {
    LOG_DEBUG(DEBUG,"Allocate worker %d to Request id %d", worker->id, new_req->id);
    new_req->wkr = worker;
    new_req->using_wkr = TRUE;

    worker->watcher.data = new_req;
    //set Request on wich worker is working
    worker->req = new_req;
    ev_io_init(&worker->watcher, wr_req_hearer_write_cb, worker->fd, EV_WRITE);
    ev_io_start(worker->loop, &worker->watcher);
  }else{
    LOG_DEBUG(DEBUG, "Could not dispatch the request");
  }
}

/** Handle connect request from Worker */
int wr_wkr_connect(wr_ctl_t *ctl, const wr_ctl_msg_t *ctl_msg) {
  LOG_FUNCTION
  int retval;
  wr_svr_t* server = ctl->svr;
  wr_wkr_t* worker = NULL;

  if(server->conf->uds) {
    if(strcmp(ctl_msg->msg.wkr.uds.str,"YES")!=0 ||
        ctl_msg->msg.wkr.sock_path.str == NULL) {
      scgi_body_add(ctl->scgi, "Invalid UDS, sock path and configuration.", strlen("Invalid UDS, sock path and configuration."));
      LOG_ERROR(SEVERE,"connect_with_worker()Invalid UDS, sock path and configuration.");
      return -1;
    }
  } else {
    if(strcmp(ctl_msg->msg.wkr.uds.str,"NO")!=0 ||
        ctl_msg->msg.wkr.port.str == NULL) {
      scgi_body_add(ctl->scgi, "Invalid UDS, sock path and configuration.", strlen("Invalid UDS, sock path and configuration."));
      LOG_ERROR(SEVERE,"connect_with_worker()Invalid UDS, sock path and configuration.");
      return -1;
    }
  }

  LOG_DEBUG(4,"Sock_path = %s, port=%s, app_name=%s, pid=%s", ctl_msg->msg.wkr.sock_path.str,
            ctl_msg->msg.wkr.port.str,
            ctl_msg->msg.wkr.app_name.str,
            ctl_msg->msg.wkr.pid.str);

  worker = wr_wkr_new(ctl);
  if(worker == NULL) {
    LOG_ERROR(WARN,"worker object alloaction failde. Returning ...");
    return -1;
  }

  worker->pid = atoi(ctl_msg->msg.wkr.pid.str);
  worker->state += WR_WKR_CONNECTING;

  // Insert newly added Worker to application list*/
  if(wr_app_wrk_insert(server, worker, ctl_msg)!=0) {
    LOG_INFO("No more workers required.");
    free(worker);
    return -1;
  }

  LOG_INFO("Worker %d with PID %d for Application %s inserted successfully. control fd = %d",
           worker->id, worker->pid, worker->app->conf->name.str,worker->ctl->fd);
  if(server->conf->uds) {
    //Connect to Worker using UNIX domain socket
    struct sockaddr_un addr;
    int len;

    if ((worker->fd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
      perror("socket()");
      LOG_ERROR(4,"socket() failed");
      // Worker is not added, Reset the high load ratio
      worker->app->high_ratio = TOTAL_WORKER_COUNT(worker->app) * WR_MAX_REQ_RATIO;
      free(worker);
      return -1;
    }
    LOG_DEBUG(3,"Socket successfully open for worker. File Descriptor is %d",worker->fd);

    setsocketoption(worker->fd);
    memset(&addr, 0, sizeof(addr));

    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path,ctl_msg->msg.wkr.sock_path.str);
    len = sizeof(addr.sun_family) + strlen(addr.sun_path);

#ifdef __APPLE__
    len++;
#endif

    if(connect(worker->fd, (struct sockaddr *)&addr,len) == -1) {
      perror("connect");
      LOG_ERROR(4,"Unable to connect with worker at socket path %s. %s Closing it.",addr.sun_path, strerror(errno));
      close_fd(worker->fd);
      worker->fd=0;
      // Worker is not added, Reset the high load ratio
      worker->app->high_ratio = TOTAL_WORKER_COUNT(worker->app) * WR_MAX_REQ_RATIO;
      free(worker);
      return -1;
    }
  } else {
    //Connect to Worker using internet socket
    struct sockaddr_in addr;
    if ((worker->fd = socket(AF_INET, SOCK_STREAM, 0)) == -1) {
      perror("socket()");
      LOG_ERROR(4,"socket() failed for worker");
      // Worker is not added, Reset the high load ratio
      worker->app->high_ratio = TOTAL_WORKER_COUNT(worker->app) * WR_MAX_REQ_RATIO;
      free(worker);
      // return if not able to connect to the first worker
      return -1;
    }
    LOG_DEBUG(3,"Socket successfully open for worker. File Descriptor is %d",worker->fd);

    setsocketoption(worker->fd);
    memset(&addr, 0, sizeof(addr));

    addr.sin_family = AF_INET;
    addr.sin_port = htons(atoi(ctl_msg->msg.wkr.port.str));
    addr.sin_addr.s_addr =inet_addr("127.0.0.1");

    if(connect(worker->fd, (struct sockaddr *)&addr,sizeof addr) == -1) {
      perror("connect");
      LOG_ERROR(4,"Unable to connect with worker at port %s. %s Closing it.",ctl_msg->msg.wkr.port.str, strerror(errno));
      close_fd(worker->fd);
      worker->fd=0;
      free(worker);
      // Worker is not added, Reset the high load ratio
      worker->app->high_ratio = TOTAL_WORKER_COUNT(worker->app) * WR_MAX_REQ_RATIO;
      return -1;
    }
  }

  if(setnonblock(worker->fd) < 0) {
    LOG_ERROR(SEVERE,"Setting worker_fd non-block failed:%s",strerror(errno));
    close_fd(worker->fd);
    free(worker);
    // Worker is not added, Reset the high load ratio
      worker->app->high_ratio = TOTAL_WORKER_COUNT(worker->app) * WR_MAX_REQ_RATIO;
    return -1;
  }
  
  wr_queue_insert(worker->app->wkr_que, worker);
  //Setting low load ratio for application, refer "wr_worker_remove_cb" in wr_server.c for details.
  worker->app->low_ratio = worker->app->wkr_que->q_count * WR_MIN_REQ_RATIO;
  ctl->wkr = worker;
  LOG_DEBUG(DEBUG,"Added Worker %d",worker->id);

  ev_io_set(&worker->watcher,worker->fd,EV_READ);

  LOG_DEBUG(DEBUG,"Allocating task to newly added worker %d",worker->id);
  //Check for pending requests
  wr_wrk_allocate(worker);
  LOG_DEBUG(5,"Successfully connected to worker");
  LOG_DEBUG(DEBUG,"Allocated task to newly added worker %d",worker->id);

  return 0;
}

///** This would get called when worker reply to PING */
//void wr_wkr_ping_reply(wr_wkr_t *worker)
//{
//  LOG_FUNCTION
//  LOG_INFO("Worker %d with pid %d replied for trial no %d", worker->id, worker->pid, worker->trials_done);
//  //worker has replied so setting WR_WORKER_REPLIED flag, and clearing WR_WORKER_PING_SENT
//  if(worker->state & WR_WKR_PING_SENT)
//  {
//    ev_timer_stop(worker->ctl->svr->ebb_svr.loop, &worker->t_wait);
//    worker->t_wait.repeat = WR_WKR_IDLE_TIME;
//    worker->state &= (~224);
//    ev_timer_again(worker->ctl->svr->ebb_svr.loop, &worker->t_wait);
//  }
//}

/** Worker add callback */
void wr_wkr_add_cb(wr_ctl_t *ctl, const wr_ctl_msg_t *ctl_msg) {
  LOG_FUNCTION
  int retval;
  retval = wr_wkr_connect(ctl, ctl_msg);

  if(retval == 0) {
    scgi_header_add(ctl->scgi, "STATUS", strlen("STATUS"), "OK", strlen("OK"));
  } else {
    LOG_ERROR(SEVERE,"failed to connect with worker");
    scgi_header_add(ctl->scgi, "STATUS", strlen("STATUS"), "ERROR", strlen("ERROR"));
  }
  wr_ctl_resp_write(ctl);
}

/** Worker remove callback */
void wr_wkr_remove_cb(wr_ctl_t *ctl, const wr_ctl_msg_t *ctl_msg) {
  LOG_FUNCTION
  wr_app_t *app = NULL;
  if(ctl->wkr ) {
    app = ctl->wkr->app;
    ctl->wkr->state += WR_WKR_DISCONNECT;
    if(ctl->wkr->state & WR_WKR_ACTIVE)
      wr_wkr_remove(ctl->wkr,1);
    else
      wr_wkr_free(ctl->wkr);
  }
  scgi_build(ctl->scgi);
  scgi_free(ctl->scgi);
  ctl->scgi = NULL;
  //TODO :Send acknowledgement signal.
  wr_ctl_resp_write(ctl);

  // Create new worker if required
  if(app && app->in_use && TOTAL_WORKER_COUNT(app) < app->conf->min_worker) {
    wr_app_wkr_add(app);
  }
}

/** Worker ping callback */
void wr_wkr_ping_cb(wr_ctl_t *ctl, const wr_ctl_msg_t *ctl_msgs) {
  LOG_FUNCTION
  wr_wkr_t *worker = ctl->wkr;
  LOG_INFO("Worker %d with pid %d replied for trial no %d", worker->id, worker->pid, worker->trials_done);
  //worker has replied so setting WR_WORKER_REPLIED flag, and clearing WR_WORKER_PING_SENT
  if(worker->state & WR_WKR_PING_SENT) {
    ev_timer_stop(ctl->svr->ebb_svr.loop, &worker->t_wait);
    worker->t_wait.repeat = WR_WKR_IDLE_TIME;
    worker->state &= (~224);
    ev_timer_again(ctl->svr->ebb_svr.loop, &worker->t_wait);
  }
  scgi_build(ctl->scgi);
  scgi_free(ctl->scgi);
  ctl->scgi = NULL;
  wr_ctl_resp_write(ctl);
}
