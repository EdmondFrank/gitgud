import React from "react"

import {currentUser} from "../auth"

class CommentForm extends React.Component {
  constructor(props) {
    super(props)
    this.bodyInput = React.createRef()
    this.handleSubmit = this.handleSubmit.bind(this)
    this.handleCancel = this.handleCancel.bind(this)
    this.handleBodyChange = this.handleBodyChange.bind(this)
    this.state = {body: props.body || ""}
  }

  componentDidMount() {
    if(currentUser) {
      this.bodyInput.current.focus()
      this.bodyInput.current.setSelectionRange(this.bodyInput.current.value.length, this.bodyInput.current.value.length);
    }
  }

  render() {
    if(currentUser) {
      return (
        <div className="comment-form">
          <form onSubmit={this.handleSubmit}>
            <div className="field">
              <div className="control">
                <textarea name="comment[body]"className="textarea" placeholder="Leave a comment" value={this.state.body} onChange={this.handleBodyChange} ref={this.bodyInput} />
              </div>
            </div>
            {(() => {
              switch(this.props.action) {
                case "new":
                  return (
                    <div className="field is-grouped is-grouped-right">
                      <div className="control">
                        <button className="button is-success" type="submit" disabled={this.state.body === ""}>Add comment</button>
                      </div>
                    </div>
                  )
                case "edit":
                  return (
                    <div className="field is-grouped is-grouped-right">
                      <div className="control">
                        <button className="button" type="reset" onClick={this.props.onCancel}>Cancel</button>
                      </div>
                      <div className="control">
                        <button className="button is-link" type="submit" disabled={this.state.body === ""}>Update comment</button>
                      </div>
                    </div>
                  )
                case "reopen":
                  return (
                    <div className="field is-grouped is-grouped-right">
                      <div className="control">
                        <button className="button" onClick={this.props.onReopen}>{this.state.body === "" ? "Reopen issue" : "Reopen and comment"}</button>
                      </div>
                      <div className="control">
                        <button className="button is-success" type="submit" disabled={this.state.body === ""}>Add comment</button>
                      </div>
                    </div>
                  )
                case "close":
                  return (
                    <div className="field is-grouped is-grouped-right">
                      <div className="control">
                        <button className="button" onClick={this.props.onClose}>{this.state.body === "" ? "Close issue" : "Close and comment"}</button>
                      </div>
                      <div className="control">
                        <button className="button is-success" type="submit" disabled={this.state.body === ""}>Add comment</button>
                      </div>
                    </div>
                  )
                default:
                  return (
                    <div className="field is-grouped is-grouped-right">
                      <div className="control">
                        <button className="button" type="reset" onClick={this.handleCancel}>Cancel</button>
                      </div>
                      <div className="control">
                        <button className="button is-success" type="submit" disabled={this.state.body === ""}>Add comment</button>
                      </div>
                    </div>
                  )
              }
            })()}
          </form>
        </div>
      )
    } else {
      return (
        <div className="comment-form">
          {!this.props.action &&
            <div className="is-pulled-right">
              <button className="delete" onClick={this.props.onCancel}>Cancel</button>
            </div>
          }
          You must <a href={`/login?redirect_to=${encodeURIComponent(window.location.pathname)}`}>login</a> in order to comment.
        </div>
      )
    }
  }

  handleSubmit(event) {
    event.preventDefault()
    if(this.props.onTyping) {
      this.props.onTyping(false)
    }
    this.props.onSubmit(this.state.body)
    this.setState({body: ""})
  }

  handleCancel(event) {
    if(this.props.onTyping) {
      if(this.state.body != "") {
        this.props.onTyping(false)
      }
    }
    this.props.onCancel()
    this.setState({body: ""})
  }

  handleBodyChange(event) {
    if(this.props.onTyping) {
      if(event.target.value != "" && this.state.body == "") {
        this.props.onTyping(true)
      } else if(event.target.value == "" && this.state.body != "") {
        this.props.onTyping(false)
      }
    }
    this.setState({body: event.target.value})
  }
}

export default CommentForm
