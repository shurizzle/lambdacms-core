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
  ( getUserAdminR
  , getUserAdminNewR
  , postUserAdminNewR
  , getUserAdminDetailR
  , getUserAdminEditR
  , postUserAdminEditR
  , deleteUserAdminDeleteR
  ) where

import LambdaCms.Core.Import
import LambdaCms.Core.AuthHelper
import qualified Data.Text as T (breakOn, concat)

getUserAdminR        :: CoreHandler Html
getUserAdminNewR     :: CoreHandler Html
postUserAdminNewR    :: CoreHandler Html
getUserAdminDetailR  :: UserId -> CoreHandler Html
getUserAdminEditR    :: UserId -> CoreHandler Html
postUserAdminEditR   :: UserId -> CoreHandler Html
deleteUserAdminDeleteR :: UserId -> CoreHandler Html

userForm :: User -> Form User
userForm u = renderDivs $ User
             <$> pure (userIdent u) -- areq textField "Ident" (Just $ userIdent u)
             <*> areq textField "Name"         (Just $ userName     u)
             <*> areq passwordConfirmField "Password" Nothing
             <*> areq textField "Email"        (Just $ userEmail    u)
             <*> pure (userToken u) -- aopt textField "Token" (Just $ userToken    u)

-- | Helper to create a user with email address
generateUserWithEmail :: Text -> IO User
generateUserWithEmail e = do
  uuid <- generateUUID
  return $ User { userIdent = uuid
                , userName = fst $ T.breakOn "@" e
                , userPassword = Nothing
                , userEmail = e
                , userToken = Nothing
                }

-- | Helper to create an empty user
emptyUser :: IO User
emptyUser = generateUserWithEmail ""

-- | Allows a user to change its password
passwordConfirmField :: (LambdaCmsAdmin master) => Field (HandlerT master IO) (Maybe Text)
passwordConfirmField = Field
    { fieldParse = \rawVals _fileVals ->
        case rawVals of
            [a, b]
                | a == b -> return $ Right $ Just $ Just a
                | otherwise -> return $ Left "Passwords don't match"
            [] -> return $ Right Nothing
            _ -> return $ Left "You must enter two values"
    , fieldView = \idAttr nameAttr otherAttrs _ _ ->
        [whamlet|
            <input id=#{idAttr} name=#{nameAttr} *{otherAttrs} type=password>
            <div>Confirm:
            <input id=#{idAttr}-confirm name=#{nameAttr} *{otherAttrs} type=password>
        |]
    , fieldEnctype = UrlEncoded
    }

getUserAdminR = do
    toParent <- getRouteToParent
    (users :: [Entity User]) <- lift $ runDB $ selectList [] []
    lambdaCoreLayout $(whamletFile "templates/user/index.hamlet")

getUserAdminNewR = do
    toParent <- getRouteToParent
    eu <- liftIO emptyUser
    (formWidget, enctype) <- lift . generateFormPost . userForm $ eu
    lambdaCoreLayout $(whamletFile "templates/user/new.hamlet")

postUserAdminNewR = do
    eu <- liftIO emptyUser
    ((formResult, _), _) <- lift . runFormPost . userForm $ eu
    case formResult of
      FormSuccess user -> do
        userId <- lift $ runDB $ insert user
        setMessage "successfully added"
        redirectUltDest $ UserAdminDetailR userId
      _ -> do
        setMessage "form error"
        redirectUltDest UserAdminNewR

getUserAdminDetailR userId = do
    toParent <- getRouteToParent
    user <- lift . runDB $ get404 userId
    lambdaCoreLayout $(whamletFile "templates/user/show.hamlet")

getUserAdminEditR userId = do
    toParent <- getRouteToParent
    user <- lift $ runDB $ get404 userId
    (formWidget, enctype) <- lift . generateFormPost . userForm $ user
    lambdaCoreLayout $(whamletFile "templates/user/edit.hamlet")

postUserAdminEditR userId = do
    eu <- liftIO emptyUser
    ((formResult, _), _) <- lift . runFormPost . userForm $ eu
    case formResult of
        FormSuccess user -> do
          _ <- lift $ runDB $ replace userId user
          setMessage "successfully replaced"
          lift $ adminLayout [whamlet|#{show user}|]
          -- redirect UserAdminR
        FormFailure f -> do
          setMessage (toHtml $ show f) -- "form error"
          redirectUltDest $ UserAdminDetailR userId
        FormMissing -> do
          redirectUltDest $ UserAdminDetailR userId

deleteUserAdminDeleteR userId = do
  _ <- lift . runDB $ get404 userId
  lift . runDB $ delete userId
  setMessage . toHtml $ T.concat ["Deleted User with id: ", toPathPiece userId]
  redirectUltDest UserAdminR
