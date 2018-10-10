/*
Specification on project:
Platform: IOS / Android
Runner: Expo
Framework: React Native
Styling: styled-component
Clean code: ESLint
Additional libraries: react-navigation, redux, redux-native-persist, redux-saga, axios
*/

/*
      Entry file
*/

import React, { Component } from 'react'
import { Provider } from 'react-redux'
import { ThemeProvider } from 'styled-components'

import store from '../store'

import MainView from './MainView'

const theme = {
  main: '#28c088',
  background: 'white',
  disabled: '#d8d8d8',
  text: '#666768',
  subTitle: '#6c7680',
  warning: '#e63046',
  error: '#e24659',
  lightWarning: 'rgba(230, 48, 70, 0.1)'
}

class App extends Component {
  render() {
    return (
      <Provider store={store}>
        <MainView />
        <AuthScreen />
      </Provider>
    )
  }
}

export default App

/*
      Redux store (with saga-redux and localstorage-redux middelwares)
*/

//midelawares
import { applyMiddleware, compose } from 'redux'
import { createLogger } from 'redux-logger'
import persistState from 'redux-localstorage'

import sagaMiddleware from './saga'

const middleware = compose(
  applyMiddleware(sagaMiddleware, createLogger()),
  persistState(['user']),
  typeof window === 'object' &&
  typeof window.devToolsExtension !== 'undefined' ? window.devToolsExtension() : f => f
)

export default middleware

//saga middleware
import createSagaMiddleware from 'redux-saga'
import rootSaga from './../sagas'

const sagaMiddleware = createSagaMiddleware()

export function runSaga() {
  return sagaMiddleware.run(rootSaga)
}

export default sagaMiddleware

//store
import { createStore } from 'redux'
import rootReducer from './reducers'

import middleware from './middleware'
import { runSaga } from './middleware/saga'

const store = createStore(rootReducer, middleware)

runSaga()

export default store

/*
      Redux reducer (with combaine)
*/

//root reducer
import { combineReducers } from 'redux'
import user from './user'

const rootReducer = combineReducers({
  user
});

export default rootReducer

//user reducer
import { SET_USER_TOKENS, USER_DATA_SUCCESS, USER_LOGOUT, USER_LOGIN, SET_PUBLIC_KEYS } from '../actions/user'

const initState = {
  logged: false,
  data: {},
  token: null,
  refreshToken: null,
  public_keys: {}
}

export default function (state = initState, action) {
  switch (action.type) {
    case SET_USER_TOKENS:
      return { ...state, ...action.tokens }
    case USER_DATA_SUCCESS:
      return { ...state, data: action.data.user }
    case USER_LOGOUT:
      return { ...initState }
    case USER_LOGIN:
      return { ...state, logged: true }
    case SET_PUBLIC_KEYS:
      return { ...state, public_keys: action.keys }
    default:
      return state
  }
}

/*
      Redux action
*/

export const USER_LOGIN = 'USER_LOGIN'

export function userLogin() {
  return {
    type: USER_LOGIN
  }
}

export const USER_LOGOUT = 'USER_LOGOUT'

export function userLogout() {
  return {
    type: USER_LOGOUT
  }
}

export const SET_PUBLIC_KEYS = 'USER/SET_PUBLIC_KEYS'

export function setPublicKeys(keys) {
  return {
    type: SET_PUBLIC_KEYS,
    keys
  }
}

/*
      Redux Saga
*/

//root saga

import { all } from 'redux-saga/effects'

import errorHandler from './errorHandler'

import user from './user'

export default function* rootSaga() {
  yield all([
    ...errorHandler,
    ...user
  ])
}

//user saga
import { put, call, takeEvery, select } from 'redux-saga/effects'
import axios from 'axios'

import { BASE_URL, USER_URL } from '../constants'
import { USER_DATA_REQUEST, userDataSuccess, userDataFailed } from '../actions/user'
import { getCredentials } from './selectors'

function fetchInitUserData(token) {
  return axios.get(`${BASE_URL}${USER_URL}`, {
    headers: { 'X-USER-TOKEN': token }
  })
}

export default [
  takeEvery(USER_DATA_REQUEST, function* (action) {
    try {
      const credentials = yield select(getCredentials)
      const res = yield call(fetchInitUserData, credentials.token)

      yield put(userDataSuccess(res.data))
    } catch (error) {
      yield put(userDataFailed(error, action))
    }
  })
]

//redux saga selector
export const getCredentials = ({ user }) => ({
  token: user.token,
  refreshToken: user.refreshToken
})

export const getUserData = ({ user }) => user.data


/*
      Constants
*/

export const BASE_URL = 'https://api.com/v1'
export const AUTH_URL = '/auth'
export const USER_URL = '/user'
export const REFRESH_TOKEN_URL = '/refresh_token'


/*
      Container (with redux-from)
*/

import React, { Component } from 'react'
import { connect } from 'react-redux'
import { bindActionCreators } from 'redux'
import { reduxForm, Field } from 'redux-form'
import styled from 'styled-components'
import { ContentBlock, Button, AvatarUploader, InputWithLabel, Select } from '../components'

import { fetchUser, updateUser } from '../actions/user'

const ProfileContent = styled(ContentBlock)`
  padding: 5px 15px 15px;
  
  form {
    padding: 15px 15px 20px;
    background-color: #fff;
  }
`

const FormWrapper = styled.form`
  .input-field:after {
    background-color: #e2e2e2;
  }
`

const ButtonBlock = styled.li`
  display: flex;
  align-items: center;
  justify-content: center;
  flex-grow: 1;
  margin-top: 20px;
`

const SubmitButton = styled(Button)`
  margin-top: 20px;
`

const AvatarBox = styled.li`
  margin-bottom: 40px;
`

function validate(values) {
  const errors = {}

  if (!/^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4}$/i.test(values.email)) {
    errors.email = 'Invalid email address'
  }

  return errors
}

class UserProfile extends Component {
  componentDidMount() {
    this.fetchUser()
  }

  onSubmit = (data) => {
    this.updateUser(data)
  }

  render() {
    const { handleSubmit } = this.props

    return (
      <ProfileContent>
        <FormWrapper form noHairlines noHairlinesBetween>
          <AvatarBox>
            <Field name="avatar_base" component={AvatarUploader} />
          </AvatarBox>
          <Field
            component={InputWithLabel}
            name="email"
            label="E-mail"
            placeholder="E-mail"
          />
          <Select
            name="gender"
            label="Gender"
            defaultOption="Select a gender..."
          >
            {genders.map(({ value }) => (
              <option value={value} key={`${value}`}>{value}</option>
            )}
          </Select>
          <Field
            component={InputWithLabel}
            name="city"
            label="City"
            placeholder="City"
          />
          <ButtonBlock>
            <SubmitButton fill raised button onClick={handleSubmit(this.onSubmit)}>
              Save
            </SubmitButton>
          </ButtonBlock>
        </FormWrapper>
      </ProfileContent>
    )
  }
}

const mapStateToProps = ({ user }) => ({
  user
})

const mapDispatchToProps = (dispatch) => bindActionCreators({
  fetchUser,
  updateUser
}, dispatch)

export default connect(mapStateToProps)(reduxForm({
  form: 'userProfile',
  validate
})(UserProfile))