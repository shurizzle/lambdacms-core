{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE FlexibleContexts    #-}

module LambdaCms.Core.Handler.User
  ( getUserAdminOverviewR
  , postUserAdminChangeRolesR
  , getUserAdminNewR
  , postUserAdminNewR
  , getUserAdminR
  , postUserAdminR
  , deleteUserAdminR
  , postUserAdminChangePasswordR
  , getUserAdminActivateR
  , postUserAdminActivateR
  ) where

import LambdaCms.Core.Import
import LambdaCms.Core.AuthHelper
import LambdaCms.Core.Message (CoreMessage)
import qualified LambdaCms.Core.Message as Msg
import LambdaCms.I18n

import Data.Time.Format
import qualified Data.Text as T (breakOn, concat, length, pack)
import qualified Data.Text.Lazy as LT (Text)

import Data.Maybe (fromMaybe)
import Data.Time.Clock
import Data.Time.Format.Human
import qualified Data.Set as S
import System.Locale
import Network.Mail.Mime
import Text.Blaze.Renderer.Text  (renderHtml)
import Control.Arrow ((&&&))
-- data type for a form to change a user's password
data ComparePassword = ComparePassword { originalPassword :: Text
                                       , confirmPassword :: Text
                                       } deriving (Show, Eq)

getUserAdminOverviewR        :: CoreHandler Html
getUserAdminNewR             :: CoreHandler Html
postUserAdminNewR            :: CoreHandler Html
getUserAdminR                :: UserId -> CoreHandler Html
postUserAdminR               :: UserId -> CoreHandler Html
postUserAdminChangePasswordR :: UserId -> CoreHandler Html
deleteUserAdminR             :: UserId -> CoreHandler Html
getUserAdminActivateR        :: UserId -> Text -> CoreHandler Html
postUserAdminActivateR        :: UserId -> Text -> CoreHandler Html

userForm :: User -> Maybe CoreMessage -> Form User
userForm u submit = renderBootstrap3 BootstrapBasicForm $ User
             <$> pure            (userIdent u)
             <*> areq textField  (bfs Msg.Username)        (Just $ userName u)
             <*> pure            (userPassword u)
             <*> areq emailField (bfs Msg.EmailAddress)   (Just $ userEmail u)
             <*> pure            (userToken u)
             <*> pure            (userCreatedAt u)
             <*> pure            (userLastLogin u)
             <*  bootstrapSubmit (BootstrapSubmit (fromMaybe Msg.Submit submit) " btn-success " [])

userRoleForm :: (LambdaCmsAdmin master) => S.Set (Roles master) -> Html -> MForm (HandlerT master IO) (FormResult [Roles master], WidgetT master IO ())
userRoleForm roles = renderBootstrap3 BootstrapBasicForm $
           areq (checkboxesField roleList) "" (Just $ S.toList roles)
           <*  bootstrapSubmit (BootstrapSubmit Msg.Submit " btn-success " [])
  where roleList = do
          y <- getYesod
          optionsPairs $ map ((T.pack . show) &&& id) $ S.toList $ getRoles y

userChangePasswordForm :: Maybe Text -> Maybe CoreMessage -> Form ComparePassword
userChangePasswordForm original submit = renderBootstrap3 BootstrapBasicForm $ ComparePassword
  <$> areq validatePasswordField (withName "original-pw" $ bfs Msg.Password) Nothing
  <*> areq comparePasswordField  (bfs Msg.Confirm) Nothing
  <*  bootstrapSubmit (BootstrapSubmit (fromMaybe Msg.Submit submit) " btn-success " [])
  where
    validatePasswordField = check validatePassword passwordField
    comparePasswordField = check comparePasswords passwordField

    validatePassword pw
      | T.length pw >= 8 = Right pw
      | otherwise = Left Msg.PasswordTooShort

    comparePasswords pw
      | pw == fromMaybe "" original = Right pw
      | otherwise = Left Msg.PasswordMismatch

-- | Helper to create a user with email address
generateUserWithEmail :: Text -> IO User
generateUserWithEmail e = do
  uuid <- generateUUID
  token <- generateActivationToken
  timeNow <- getCurrentTime
  return $ User { userIdent     = uuid
                , userName      = fst $ T.breakOn "@" e
                , userPassword  = Nothing
                , userEmail     = e
                , userToken     = Just token
                , userCreatedAt = timeNow
                , userLastLogin = timeNow
                }

-- | Helper to create an empty user
emptyUser :: IO User
emptyUser = generateUserWithEmail ""

-- | Validate an activation token
validateUserToken :: User -> Text -> Maybe Bool
validateUserToken user token =
  case userToken user of
   Just t
     | t == token -> Just True  -- ^ tokens match
     | otherwise  -> Just False -- ^ tokens don't match
   Nothing        -> Nothing    -- ^ there is no token (account already actived)

sendAccountActivationToken :: (LambdaCmsAdmin a) => a -> User -> LT.Text -> LT.Text -> IO ()
sendAccountActivationToken core user body bodyHtml = do
     mail <- simpleMail
             (Address (Just $ userName user) (userEmail user))
             (Address (Just "LambdaCms") "lambdacms@example.com")
             "Account Activation"
             (body)
             (bodyHtml)
             []
     lambdaCmsSendMail core mail

getUserAdminOverviewR = do
  tp <- getRouteToParent
  timeNow <- liftIO getCurrentTime
  lift $ do
    hrtLocale <- lambdaCmsHumanTimeLocale
    (users :: [Entity User]) <- runDB $ selectList [] []
    adminLayout $ do
      setTitleI Msg.UserOverview
      $(whamletFile "templates/user/index.hamlet")

getUserAdminNewR = do
  tp <- getRouteToParent
  eu <- liftIO emptyUser
  lift $ do
    (formWidget, enctype) <- generateFormPost $ userForm eu (Just Msg.Create)
    adminLayout $ do
      setTitleI Msg.NewUser
      $(whamletFile "templates/user/new.hamlet")

postUserAdminNewR = do
    eu <- liftIO emptyUser
    tp <- getRouteToParent
    ((formResult, formWidget), enctype) <- lift . runFormPost $ userForm eu (Just Msg.Create)
    case formResult of
      FormSuccess user -> do

        case userToken user of
         Just token -> do
           userId <- lift $ runDB $ insert user
           html <- lift $ withUrlRenderer $(hamletFile "templates/mail/activation-html.hamlet")
           text <- lift $ withUrlRenderer $(hamletFile "templates/mail/activation-text.hamlet")
           y <- lift getYesod
           let bodyHtml = renderHtml html
               bodyText = renderHtml text

           _ <- liftIO $ sendAccountActivationToken y user bodyText bodyHtml
           lift $ setMessageI Msg.SuccessCreate
           redirectUltDest $ UserAdminR userId
         Nothing -> error "No token found."
      _ -> do
        tp <- getRouteToParent
        lift . adminLayout $ do
          setTitleI Msg.NewUser
          $(whamletFile "templates/user/new.hamlet")

getUserAdminR userId = do
    tp <- getRouteToParent
    timeNow <- liftIO getCurrentTime
    lift $ do
      user <- runDB $ get404 userId
      ur <- runDB $ getUserRoles userId
      hrtLocale <- lambdaCmsHumanTimeLocale
      (urWidget, urEnctype)     <- generateFormPost $ userRoleForm ur                                  -- user role form
      (formWidget, enctype)     <- generateFormPost $ userForm user (Just Msg.Save)                    -- user form
      (pwFormWidget, pwEnctype) <- generateFormPost $ userChangePasswordForm Nothing (Just Msg.Change) -- user password form
      adminLayout $ do
        setTitleI . Msg.EditUser $ userName user
        $(whamletFile "templates/user/edit.hamlet")

postUserAdminR userId = do
  user <- lift . runDB $ get404 userId
  timeNow <- liftIO getCurrentTime
  hrtLocale <- lift lambdaCmsHumanTimeLocale
  ur <- lift . runDB $ getUserRoles userId
  (urWidget, urEnctype)               <- lift . generateFormPost $ userRoleForm ur
  (pwFormWidget, pwEnctype)           <- lift . generateFormPost $ userChangePasswordForm Nothing (Just Msg.Change)
  ((formResult, formWidget), enctype) <- lift . runFormPost $ userForm user (Just Msg.Save)
  case formResult of
   FormSuccess updatedUser -> do
     _ <- lift $ runDB $ update userId [UserName =. userName updatedUser, UserEmail =. userEmail updatedUser]
     lift $ setMessageI Msg.SuccessReplace
     redirect $ UserAdminR userId
   _ -> do
     tp <- getRouteToParent
     lift . adminLayout $ do
       setTitleI . Msg.EditUser $ userName user
       $(whamletFile "templates/user/edit.hamlet")

postUserAdminChangePasswordR userId = do
  user <- lift . runDB $ get404 userId
  timeNow <- liftIO getCurrentTime
  hrtLocale <- lift lambdaCmsHumanTimeLocale
  ur <- lift . runDB $ getUserRoles userId
  (urWidget, urEnctype) <- lift . generateFormPost $ userRoleForm ur
  (formWidget, enctype) <- lift . generateFormPost $ userForm user (Just Msg.Save)
  opw <- lookupPostParam "original-pw"
  ((formResult, pwFormWidget), pwEnctype) <- lift . runFormPost $ userChangePasswordForm opw (Just Msg.Change)
  case formResult of
   FormSuccess f -> do
     _ <- lift . runDB $ update userId [UserPassword =. Just (originalPassword f)]
     lift $ setMessageI Msg.SuccessChgPwd
     redirect $ UserAdminR userId
   _ -> do
     tp <- getRouteToParent
     lift . adminLayout $ do
       setTitleI . Msg.EditUser $ userName user
       $(whamletFile "templates/user/edit.hamlet")


postUserAdminChangeRolesR userId = do
  timeNow <- liftIO getCurrentTime
  user <- lift . runDB $ get404 userId
  hrtLocale <- lift lambdaCmsHumanTimeLocale
  ur <- lift . runDB $ getUserRoles userId
  ((urResult, urWidget), urEnctype) <- lift . runFormPost      $ userRoleForm ur
  (pwFormWidget, pwEnctype)         <- lift . generateFormPost $ userChangePasswordForm Nothing (Just Msg.Change)
  (formWidget, enctype)             <- lift . generateFormPost $ userForm user (Just Msg.Save)
  case urResult of
    FormSuccess roles -> do
      lift . runDB $ setUserRoles userId (S.fromList roles)
      redirect $ UserAdminR userId
    _ -> do
      tp <- getRouteToParent
      lift . adminLayout $ do
        $(whamletFile "templates/user/edit.hamlet")

deleteUserAdminR userId = do
  lift $ do
    user <- runDB $ get404 userId
    _ <- runDB $ delete userId
    setMessageI Msg.SuccessDelete
  redirectUltDest UserAdminOverviewR

getUserAdminActivateR userId token = do
  user <- lift . runDB $ get404 userId
  case validateUserToken user token of
   Just True -> do
     tp <- getRouteToParent
     (pwFormWidget, pwEnctype) <- lift . generateFormPost $ userChangePasswordForm Nothing (Just Msg.Change)
     lift . adminLayout $ do
       setTitle . toHtml $ userName user
       $(whamletFile "templates/user/activate.hamlet")
   Just False -> lift . adminLayout $ do
     setTitleI Msg.TokenMismatch
     $(whamletFile "templates/user/tokenmismatch.hamlet")
   Nothing -> lift . adminLayout $ do
     setTitleI Msg.AccountAlreadyActivated
     $(whamletFile "templates/user/account-already-activated.hamlet")

postUserAdminActivateR userId token = do
  user <- lift . runDB $ get404 userId
  tp <- getRouteToParent
  case validateUserToken user token of
   Just True -> do
     opw <- lookupPostParam "original-pw"
     ((formResult, pwFormWidget), pwEnctype) <- lift . runFormPost $ userChangePasswordForm opw (Just Msg.Change)
     case formResult of
      FormSuccess f -> do
        _ <- lift . runDB $ update userId [UserPassword =. Just (originalPassword f), UserToken =. Nothing]
        setMessage "Msg: Successfully activated"
        redirect $ AdminHomeR
      _ -> do
        lift . adminLayout $ do
          setTitle . toHtml $ userName user
          $(whamletFile "templates/user/activate.hamlet")
   Just False -> lift . adminLayout $ do
     setTitleI Msg.TokenMismatch
     $(whamletFile "templates/user/tokenmismatch.hamlet")
   Nothing -> lift . adminLayout $ do
     setTitleI Msg.AccountAlreadyActivated
     $(whamletFile "templates/user/account-already-activated.hamlet")
